@testable import ClerkKit
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct ClerkPreviewTests {
  @Test
  func repeatedPreviewsUseFreshInMemoryRuntimes() async throws {
    let signedIn = makePreview { $0.isSignedIn = true }
    let firstRuntime = signedIn.runtime
    let firstStorage = signedIn.dependencies.appLocalKeychain
    try firstStorage.set(Data([1]), forKey: "preview-marker")

    let signedOut = makePreview { $0.isSignedIn = false }
    let secondStorage = signedOut.dependencies.appLocalKeychain

    #expect(signedIn !== signedOut)
    #expect(signedIn.user != nil)
    #expect(signedOut.user == nil)
    #expect(!firstRuntime.isCurrent)
    #expect(signedOut.runtime.isCurrent)
    #expect(firstStorage is ClerkKit.InMemoryKeychain)
    #expect(secondStorage is ClerkKit.InMemoryKeychain)
    #expect(signedOut.dependencies.keychain is ClerkKit.InMemoryKeychain)
    #expect(try secondStorage.data(forKey: "preview-marker") == nil)
    #expect(!signedOut.options.telemetryEnabled)
    #expect(!signedOut.options.watchConnectivityEnabled)

    _ = try await signedOut.refreshClient()
    _ = try await signedOut.refreshEnvironment()
    #expect(signedOut.user == nil)
  }

  @Test
  func previewRetiresPreviouslyConfiguredRuntime() throws {
    let existing = try Clerk.configureForTesting(
      publishableKey: "pk_test_bW9jay5jbGVyay5hY2NvdW50cy5kZXYk",
      options: .init(telemetryEnabled: false),
      keychainStorage: ClerkKit.InMemoryKeychain()
    )
    defer { existing.cleanupManagers() }
    let previousRuntime = existing.runtime

    let preview = makePreview { $0.isSignedIn = false }

    #expect(!previousRuntime.isCurrent)
    #expect(preview.runtime.isCurrent)
    #expect(preview.dependencies is MockDependencyContainer)
  }

  @Test
  func previewDoesNotMarkRealBiometricInstallation() throws {
    let domain = "ClerkPreviewTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: domain))
    let previousDefaults = Clerk.installationMarkerUserDefaults
    let previousProvider = Clerk.biometricCredentialAppIdentifierProvider
    Clerk.installationMarkerUserDefaults = defaults
    Clerk.biometricCredentialAppIdentifierProvider = { "preview-test-app" }
    defer {
      Clerk.installationMarkerUserDefaults = previousDefaults
      Clerk.biometricCredentialAppIdentifierProvider = previousProvider
      defaults.removePersistentDomain(forName: domain)
    }

    let clerk = makePreview { $0.isSignedIn = true }
    let marker = Clerk.biometricCredentialInstallationMarkerKey(
      for: clerk.options.keychainConfig,
      appIdentifier: "preview-test-app"
    )

    #expect(defaults.object(forKey: marker) == nil)
  }

  @Test
  func replacementPreviewDoesNotReuseRetiredTokenRequest() async throws {
    await SessionTokenFetcher.shared.reset()
    let gate = PreviewTokenGate()
    let oldTransport = FakeTransport.mockDefaults()
    oldTransport.stub(SessionAPI.fetchToken(sessionId: Session.mock.id, template: nil, params: nil)) { _ in
      await gate.suspend()
      return .mock
    }
    let old = makePreview { $0.transport = oldTransport }
    let oldSession = try #require(old.session)
    let oldRequest = Task { try await SessionTokenFetcher.shared.getToken(oldSession) }
    await gate.waitStarted()

    let newTransport = FakeTransport.mockDefaults()
    let replacement = makePreview { $0.transport = newTransport }
    let newSession = try #require(replacement.session)
    let newRequest = Task {
      try await SessionTokenFetcher.shared.getToken(newSession, onInFlightTaskShared: { _ in
        Task { @MainActor in gate.release() }
      })
    }
    let newResult = await newRequest.result
    gate.release()
    let oldResult = await oldRequest.result

    switch newResult {
    case let .success(token):
      #expect(token != nil)
    case let .failure(error):
      Issue.record(error)
    }
    #expect(newTransport.calls.count == 1)
    #expect(throws: CancellationError.self) { try oldResult.get() }
    await SessionTokenFetcher.shared.reset()
  }

  @Test
  func requestsWithinOnePreviewStillShareTokenFetch() async throws {
    await SessionTokenFetcher.shared.reset()
    let gate = PreviewTokenGate()
    let transport = FakeTransport.mockDefaults()
    transport.stub(SessionAPI.fetchToken(sessionId: Session.mock.id, template: nil, params: nil)) { _ in
      await gate.suspend()
      return .mock
    }
    let clerk = makePreview { $0.transport = transport }
    let session = try #require(clerk.session)
    let first = Task { try await SessionTokenFetcher.shared.getToken(session) }
    await gate.waitStarted()
    let second = Task {
      try await SessionTokenFetcher.shared.getToken(session, onInFlightTaskShared: { _ in
        Task { @MainActor in gate.release() }
      })
    }

    #expect(try await first.value != nil)
    #expect(try await second.value != nil)
    #expect(transport.calls.count == 1)
    await SessionTokenFetcher.shared.reset()
  }

  @Test
  func emailCreationUsesPreviewTransport() async throws {
    var fixture = EmailAddress.mock
    fixture.id = "email_preview"
    fixture.emailAddress = "preview@example.com"
    let transport = FakeTransport.mockDefaults()
    transport.stub(EmailAddressAPI.create(email: fixture.emailAddress), returning: ClientResponse(response: fixture, client: nil))

    let clerk = makePreview { preview in
      preview.transport = transport
    }
    let user = try #require(clerk.user)
    let created = try await user.createEmailAddress(fixture.emailAddress)

    #expect(created == fixture)
    #expect(transport.calls.count == 1)
    let call = try #require(transport.calls.first)
    #expect(call.method == .post)
    #expect(call.path == "/v1/me/email_addresses")
    #expect(call.body?["email_address"]?.stringValue == fixture.emailAddress)
  }

  @Test
  func emailCreationPropagatesPreviewTransportErrors() async throws {
    let transport = FakeTransport.mockDefaults()
    transport.stub(EmailAddressAPI.create(email: "preview@example.com")) { _ in
      throw PreviewError.rejected
    }

    let clerk = makePreview { preview in
      preview.transport = transport
    }
    let user = try #require(clerk.user)

    await #expect(throws: PreviewError.rejected) {
      try await user.createEmailAddress("preview@example.com")
    }
    #expect(transport.calls.count == 1)
  }

  #if canImport(AuthenticationServices) && !os(watchOS) && !os(tvOS)
  @Test
  func passkeyCreationReturnsThePreviewPasskeyWithoutPlatformRegistration() async throws {
    let clerk = makePreview { _ in }
    let user = try #require(clerk.user)

    let environmentKey = "XCODE_RUNNING_FOR_PREVIEWS"
    setenv(environmentKey, "1", 1)
    defer { unsetenv(environmentKey) }
    let passkey = try await user.createPasskey()

    #expect(passkey.id == Passkey.mock.id)
  }
  #endif

  private func makePreview(_ configure: @escaping (PreviewBuilder) -> Void) -> Clerk {
    let environmentKey = "XCODE_RUNNING_FOR_PREVIEWS"
    let previousValue = ProcessInfo.processInfo.environment[environmentKey]
    setenv(environmentKey, "1", 1)
    defer {
      if let previousValue {
        setenv(environmentKey, previousValue, 1)
      } else {
        unsetenv(environmentKey)
      }
    }

    let clerk = Clerk.preview(preview: configure)
    clerk.cleanupManagers()
    return clerk
  }

  private enum PreviewError: Error {
    case rejected
  }
}

@MainActor
private final class PreviewTokenGate {
  private var response: CheckedContinuation<Void, Never>?
  private var started: CheckedContinuation<Void, Never>?

  func suspend() async {
    await withCheckedContinuation {
      response = $0
      started?.resume()
      started = nil
    }
  }

  func waitStarted() async {
    if response != nil { return }
    await withCheckedContinuation { started = $0 }
  }

  func release() {
    response?.resume()
    response = nil
  }
}
