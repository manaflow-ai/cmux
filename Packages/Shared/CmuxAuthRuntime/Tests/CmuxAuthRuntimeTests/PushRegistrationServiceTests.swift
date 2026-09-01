import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Records every URLRequest the push service performs, returning 200.
final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    // URLProtocol's synchronous callback must record before it reports
    // completion, so the recorder uses a documented synchronous lock.
    static let recorder = RequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        RecordingURLProtocol.recorder.record(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMethods: [String] = []
    private var storedRequests: [URLRequest] = []

    var methods: [String] { lock.withLock { storedMethods } }
    var requests: [URLRequest] { lock.withLock { storedRequests } }

    func record(_ request: URLRequest) {
        lock.withLock {
            storedMethods.append(request.httpMethod ?? "?")
            storedRequests.append(request)
        }
    }
    func reset() {
        lock.withLock {
            storedMethods = []
            storedRequests = []
        }
    }
}

struct FakeTokenProvider: TokenProviding {
    var access: String? = "access"
    var refresh: String? = "refresh"
    var accountID: String = "push-user-1"
    var generation: UInt64 = 1
    func authenticatedSessionSnapshot() async throws
        -> AuthenticatedSessionSnapshot {
        guard let access, let refresh else { throw AuthError.unauthorized }
        return AuthenticatedSessionSnapshot(
            generation: generation,
            accountID: accountID,
            accessToken: access,
            refreshToken: refresh
        )
    }
    func isAuthenticatedSessionCurrent(
        _ snapshot: AuthenticatedSessionSnapshot
    ) async -> Bool {
        snapshot.generation == generation && snapshot.accountID == accountID
    }
    func accessToken() async throws -> String {
        guard let access else { throw AuthError.unauthorized }
        return access
    }
    func storedAccessToken() async -> String? { access }
    func refreshToken() async -> String? { refresh }
    func forceRefreshAccessToken() async throws -> String {
        guard let access else { throw AuthError.unauthorized }
        return access
    }
}

actor MutablePushTokenProvider: TokenProviding {
    private var value: AuthenticatedSessionSnapshot?

    init(
        accountID: String,
        accessToken: String,
        refreshToken: String,
        generation: UInt64 = 1
    ) {
        self.value = AuthenticatedSessionSnapshot(
            generation: generation,
            accountID: accountID,
            accessToken: accessToken,
            refreshToken: refreshToken
        )
    }

    func switchSession(
        accountID: String,
        accessToken: String,
        refreshToken: String
    ) {
        value = AuthenticatedSessionSnapshot(
            generation: (value?.generation ?? 0) + 1,
            accountID: accountID,
            accessToken: accessToken,
            refreshToken: refreshToken
        )
    }

    func clearSession() {
        value = nil
    }

    func authenticatedSessionSnapshot() async throws
        -> AuthenticatedSessionSnapshot {
        guard let value else { throw AuthError.unauthorized }
        return value
    }

    func isAuthenticatedSessionCurrent(
        _ snapshot: AuthenticatedSessionSnapshot
    ) async -> Bool {
        value?.generation == snapshot.generation
            && value?.accountID == snapshot.accountID
    }

    func accessToken() async throws -> String {
        guard let value else { throw AuthError.unauthorized }
        return value.accessToken
    }

    func storedAccessToken() async -> String? { value?.accessToken }
    func refreshToken() async -> String? { value?.refreshToken }

    func forceRefreshAccessToken() async throws -> String {
        try await accessToken()
    }
}

actor RetryDelayRecorder {
    private(set) var values: [Duration] = []

    func record(_ value: Duration) {
        values.append(value)
    }
}

// The push service records every request into the process-wide
// `RecordingURLProtocol.recorder` singleton (URLProtocol only accepts protocol
// *types*, not per-instance recorders, so the recorder must be reachable
// statically). The reset-then-assert-aggregate tests below (e.g.
// `registeringWhileDisabledCachesButDoesNotUpload`) call `recorder.reset()` and
// then assert on the aggregate `methods`. Swift Testing runs `@Test` functions
// in parallel by default, so without serialization a sibling test can reset or
// append to the same singleton between this test's reset and its assertion,
// failing nondeterministically. `.serialized` removes that interleaving.
@Suite(.serialized) struct PushRegistrationServiceTests {
    private func testPendingUnregisterStoreURL(for suite: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("push-cleanup-\(suite).sqlite3")
    }

    private func pendingUnregisters(
        suite: String,
        accountID: String
    ) -> [PendingUnregister] {
        (try? PendingUnregisterStore(
            databaseURL: testPendingUnregisterStoreURL(for: suite)
        ).batch(accountID: accountID, limit: 100)) ?? []
    }

    private func makeService(
        tokenProvider: any TokenProviding = FakeTokenProvider()
    ) -> (PushRegistrationService, UserDefaults) {
        let suite = "push-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        let service = PushRegistrationService(
            tokenProvider: tokenProvider,
            apiBaseURL: "https://example.test",
            bundleID: "dev.cmux.ios",
            apnsEnvironment: "sandbox",
            suiteName: suite,
            pendingUnregisterStoreURL: testPendingUnregisterStoreURL(
                for: suite
            ),
            session: URLSession(configuration: configuration)
        )
        return (service, defaults)
    }

    private func makeScriptedService(
        tokenProvider: any TokenProviding = FakeTokenProvider(),
        retryDelays: [Duration] = [],
        suite: String = "push-scripted-\(UUID().uuidString)",
        accountID: String? = "push-user-1",
        seedDefaults: (UserDefaults) -> Void = { _ in },
        retrySleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await ContinuousClock().sleep(for: $0)
        },
        sessionSnapshotTimeout: Duration = .seconds(15),
        sessionSnapshotClock: any Clock<Duration> = ContinuousClock(),
        pendingUnregisterStoreURL: URL? = nil
    ) -> (PushRegistrationService, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        seedDefaults(defaults)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PushRegistrationURLProtocol.self]
        let provider: any TokenProviding
        if let fake = tokenProvider as? FakeTokenProvider,
           let accountID {
            provider = FakeTokenProvider(
                access: fake.access,
                refresh: fake.refresh,
                accountID: accountID,
                generation: fake.generation
            )
        } else {
            provider = tokenProvider
        }
        let service = PushRegistrationService(
            tokenProvider: provider,
            apiBaseURL: "https://example.test",
            bundleID: "dev.cmux.ios.push1",
            apnsEnvironment: "sandbox",
            suiteName: suite,
            pendingUnregisterStoreURL: pendingUnregisterStoreURL
                ?? testPendingUnregisterStoreURL(for: suite),
            session: URLSession(configuration: configuration),
            retryDelays: retryDelays,
            retryJitter: { _ in 1 },
            retrySleep: retrySleep,
            sessionSnapshotTimeout: sessionSnapshotTimeout,
            sessionSnapshotClock: sessionSnapshotClock
        )
        return (service, defaults)
    }

    private func wait(
        for state: PushRegistrationBackendState,
        from service: PushRegistrationService,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while await service.snapshot.backendState != state {
            guard clock.now < deadline else { return false }
            try? await clock.sleep(for: .milliseconds(1))
        }
        return true
    }

    @Test func disabledByDefault() async {
        let (service, _) = makeService()
        #expect(await service.isEnabled == false)
    }

    @Test func registeringWhileDisabledCachesButDoesNotUpload() async {
        await RecordingURLProtocol.recorder.reset()
        let (service, _) = makeService()
        await service.register(deviceToken: Data([0xAB, 0xCD]))
        // No upload because notifications are off.
        #expect(await RecordingURLProtocol.recorder.methods.isEmpty)
    }

    @Test func enablingUploadsCachedToken() async {
        await RecordingURLProtocol.recorder.reset()
        let (service, defaults) = makeService()
        await service.register(deviceToken: Data([0xAB, 0xCD]))
        await service.setEnabled(true)
        #expect(defaults.bool(forKey: "cmux.notifications.pushEnabled"))
        #expect(await RecordingURLProtocol.recorder.methods.contains("POST"))
    }

    @Test func disablingDeletesServerToken() async {
        await RecordingURLProtocol.recorder.reset()
        let (service, _) = makeService()
        await service.register(deviceToken: Data([0xAB, 0xCD]))
        await service.setEnabled(true)
        await service.setEnabled(false)
        #expect(await RecordingURLProtocol.recorder.methods.contains("DELETE"))
    }

    @Test func signOutUnregisterAuthenticatesWithCapturedCredentials() async {
        // Local-first sign-out clears the live token provider before the
        // push-token DELETE runs, so the captured pair must authenticate the
        // request on its own (the provider would return nothing and the DELETE
        // used to be silently skipped).
        let (service, _) = makeService(
            tokenProvider: FakeTokenProvider(access: nil, refresh: nil)
        )
        await service.register(deviceToken: Data([0xAB, 0xCD]))

        await service.unregisterFromServer(
            accessToken: "captured-access",
            refreshToken: "captured-refresh"
        )

        // The recorder is shared by parallel tests; select this test's request
        // by its unique captured credential instead of taking the first one.
        var request: URLRequest?
        for _ in 0..<1000 where request == nil {
            request = await RecordingURLProtocol.recorder.requests.first {
                $0.value(forHTTPHeaderField: "Authorization") == "Bearer captured-access"
            }
            await Task.yield()
        }
        #expect(request?.httpMethod == "DELETE")
        #expect(request?.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == "captured-refresh")
        #expect(
            request?.value(forHTTPHeaderField: "X-Cmux-App-Namespace")
                == "dev.cmux.ios"
        )
    }

    @Test func signOutUnregisterNeverFallsBackToLiveProvider() async {
        // The sign-out overload runs after the local-first clear emptied the
        // live token provider. When the captured pair is incomplete (the
        // access-token mint failed offline), it must skip the DELETE rather
        // than fall back to the live provider: a sign-in racing the bounded
        // teardown can repopulate the provider with the NEXT account's
        // tokens, and the DELETE would then unregister the wrong account.
        let (service, _) = makeService(
            tokenProvider: FakeTokenProvider(access: "next-user-access", refresh: "next-user-refresh")
        )
        await service.register(deviceToken: Data([0xEE, 0xFF]))

        await service.unregisterFromServer(accessToken: nil, refreshToken: "captured-refresh")

        // The unregister call has fully completed, so any DELETE it issued is
        // already recorded. None may carry the live (next account's) Bearer.
        let hijacked = await RecordingURLProtocol.recorder.requests.contains {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer next-user-access"
        }
        #expect(hijacked == false)
    }

    @Test func offlineSignOutPersistsOwnerScopedUnregisterBeforeCredentialValidation() async {
        await PushRegistrationURLProtocol.script.reset([.response(200)])
        let suite = "push-offline-signout-\(UUID().uuidString)"
        let (service, defaults) = makeScriptedService(
            tokenProvider: FakeTokenProvider(access: "next-user-access", refresh: "next-user-refresh"),
            suite: suite,
            accountID: nil
        )
        defaults.set("ab", forKey: "cmux.notifications.deviceTokenHex")
        defaults.set("old-user", forKey: "cmux.notifications.registeredAccountID")

        await service.unregisterFromServer(
            accessToken: nil,
            refreshToken: "captured-refresh"
        )

        #expect(pendingUnregisters(
            suite: suite,
            accountID: "old-user"
        ) == [PendingUnregister(tokenHex: "ab", accountID: "old-user")])
        #expect(
            defaults.string(forKey: "cmux.notifications.pendingUnregisterToken")
                == nil
        )
        #expect(
            defaults.string(forKey: "cmux.notifications.pendingUnregisterAccountID")
                == nil
        )
        #expect(await PushRegistrationURLProtocol.script.requests.isEmpty)

        let (returnedService, _) = makeScriptedService(
            tokenProvider: FakeTokenProvider(
                access: "returned-access",
                refresh: "returned-refresh"
            ),
            suite: suite,
            accountID: "old-user"
        )
        await returnedService.syncTokenIfPossible()

        #expect(
            await PushRegistrationURLProtocol.script.requests.last?
                .value(forHTTPHeaderField: "Authorization")
                == "Bearer returned-access"
        )
    }

    @Test func signOutNeverUsesCapturedAccountBToDeleteRegisteredAccountA() async {
        await PushRegistrationURLProtocol.script.reset([.response(200)])
        let suite = "push-signout-owner-mismatch-\(UUID().uuidString)"
        let (service, defaults) = makeScriptedService(
            tokenProvider: FakeTokenProvider(
                access: "b-live-access",
                refresh: "b-live-refresh"
            ),
            suite: suite,
            accountID: "account-b"
        )
        defaults.set("aa", forKey: "cmux.notifications.deviceTokenHex")
        defaults.set(
            "account-a",
            forKey: "cmux.notifications.registeredAccountID"
        )

        await service.unregisterFromServer(
            accountID: "account-b",
            accessToken: "b-captured-access",
            refreshToken: "b-captured-refresh"
        )

        #expect(await PushRegistrationURLProtocol.script.requests.isEmpty)
        #expect(
            defaults.string(
                forKey: "cmux.notifications.registeredAccountID"
            ) == "account-a"
        )
        #expect(pendingUnregisters(
            suite: suite,
            accountID: "account-a"
        ) == [PendingUnregister(tokenHex: "aa", accountID: "account-a")])
        #expect(pendingUnregisters(
            suite: suite,
            accountID: "account-b"
        ).isEmpty)
    }

    @Test func legacySignOutCannotProveRegisteredOwnerMatchesCredentials() async {
        await PushRegistrationURLProtocol.script.reset([.response(200)])
        let suite = "push-signout-legacy-owner-\(UUID().uuidString)"
        let (service, defaults) = makeScriptedService(
            suite: suite,
            accountID: "account-a"
        )
        defaults.set("aa", forKey: "cmux.notifications.deviceTokenHex")
        defaults.set(
            "account-a",
            forKey: "cmux.notifications.registeredAccountID"
        )

        await service.unregisterFromServer(
            accessToken: "unproven-access",
            refreshToken: "unproven-refresh"
        )

        #expect(await PushRegistrationURLProtocol.script.requests.isEmpty)
        #expect(pendingUnregisters(
            suite: suite,
            accountID: "account-a"
        ) == [PendingUnregister(tokenHex: "aa", accountID: "account-a")])
    }

    @Test func enabledWithoutAPNsTokenReportsAwaitingTokenInsteadOfReady() async {
        let (service, _) = makeScriptedService()

        await service.setEnabled(true)

        #expect(await service.snapshot == PushRegistrationSnapshot(
            isEnabled: true,
            hasDeviceToken: false,
            backendState: .awaitingDeviceToken
        ))
    }

    @Test func successfulUploadIsTheOnlyPathToBackendReady() async {
        await PushRegistrationURLProtocol.script.reset([.response(200)])
        let (service, _) = makeScriptedService()

        await service.register(deviceToken: Data(repeating: 0xAB, count: 32))
        await service.setEnabled(true)

        #expect(await service.snapshot.backendState == .registered)
    }

    @Test func concurrentSameTokenSyncsShareOnePost() async {
        let started = TestPhaseSignal()
        let blocker = TestContinuationBlocker()
        await PushRegistrationURLProtocol.script.reset([
            .gatedResponse(200, started: started, blocker: blocker),
        ])
        let (service, defaults) = makeScriptedService()
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")
        defaults.set("aa", forKey: "cmux.notifications.deviceTokenHex")

        let first = Task { await service.syncTokenIfPossible() }
        await started.waitUntilStarted()
        let second = Task { await service.syncTokenIfPossible() }
        for _ in 0..<10 { await Task.yield() }
        await blocker.release()
        await first.value
        await second.value

        #expect(
            await PushRegistrationURLProtocol.script.requests
                .map(\.httpMethod) == ["POST"]
        )
        #expect(await service.snapshot.backendState == .registered)
    }

    @Test func unconfiguredProviderCannotReportBackendReady() async {
        await PushRegistrationURLProtocol.script.reset([
            .response(
                200,
                json: #"{"ok":true,"pushServiceConfigured":false}"#
            ),
        ])
        let (service, defaults) = makeScriptedService(retryDelays: [])

        await service.register(deviceToken: Data(repeating: 0xAB, count: 32))
        await service.setEnabled(true)

        #expect(
            await service.snapshot.backendState
                == .failed(.serviceUnavailable)
        )
        #expect(
            defaults.string(
                forKey: "cmux.notifications.registeredAccountID"
            ) == "push-user-1"
        )
    }

    @Test func unconfiguredProviderRetriesWithoutLosingCommittedOwnership() async {
        await PushRegistrationURLProtocol.script.reset([
            .response(
                200,
                json: #"{"ok":true,"pushServiceConfigured":false}"#
            ),
            .response(200),
        ])
        let (service, defaults) = makeScriptedService(retryDelays: [.zero])

        await service.register(deviceToken: Data(repeating: 0xAB, count: 32))
        await service.setEnabled(true)

        #expect(
            await PushRegistrationURLProtocol.script.waitForRequestCount(2)
        )
        #expect(await wait(for: .registered, from: service))
        #expect(
            defaults.string(
                forKey: "cmux.notifications.registeredAccountID"
            ) == "push-user-1"
        )
    }

    @Test func authenticationFailureRemainsVisibleAndDoesNotRetry() async {
        await PushRegistrationURLProtocol.script.reset([
            .response(401, json: #"{"error":"unauthorized"}"#),
            .response(200),
        ])
        let (service, _) = makeScriptedService(retryDelays: [.zero])

        await service.register(deviceToken: Data(repeating: 0xAB, count: 32))
        await service.setEnabled(true)

        #expect(await service.snapshot.backendState == .failed(.authenticationRequired))
        #expect(await PushRegistrationURLProtocol.script.requests.count == 1)
    }

    @Test func recoverableServiceFailureRetriesToReady() async {
        await PushRegistrationURLProtocol.script.reset([
            .response(503, json: #"{"error":"push_service_not_configured"}"#),
            .response(200),
        ])
        let (service, _) = makeScriptedService(retryDelays: [.zero])

        await service.register(deviceToken: Data(repeating: 0xAB, count: 32))
        await service.setEnabled(true)

        #expect(
            await PushRegistrationURLProtocol.script.waitForRequestCount(2)
        )
        #expect(await wait(for: .registered, from: service))
        #expect(await service.snapshot.backendState == .registered)
        #expect(await PushRegistrationURLProtocol.script.requests.count == 2)
    }

    @Test(arguments: [408, 425])
    func transientHTTPStatusRetriesAndHonorsRetryAfter(
        statusCode: Int
    ) async {
        await PushRegistrationURLProtocol.script.reset([
            .response(statusCode, headers: ["Retry-After": "0"]),
            .response(200),
        ])
        let (service, _) = makeScriptedService(
            retryDelays: [.seconds(30)]
        )

        await service.register(deviceToken: Data(repeating: 0xAB, count: 32))
        await service.setEnabled(true)
        #expect(
            await PushRegistrationURLProtocol.script.waitForRequestCount(2)
        )
        #expect(await wait(for: .registered, from: service))

        #expect(await service.snapshot.backendState == .registered)
        #expect(await PushRegistrationURLProtocol.script.requests.count == 2)
    }

    @Test func rateLimitHonorsRetryAfterBeforeRecovering() async {
        await PushRegistrationURLProtocol.script.reset([
            .response(
                429,
                headers: ["Retry-After": "0"],
                json: #"{"error":"rate_limited","retryAfterSeconds":0}"#
            ),
            .response(200),
        ])
        let (service, _) = makeScriptedService(retryDelays: [.seconds(30)])

        await service.register(deviceToken: Data(repeating: 0xAB, count: 32))
        await service.setEnabled(true)

        #expect(
            await PushRegistrationURLProtocol.script.waitForRequestCount(2)
        )
        #expect(await wait(for: .registered, from: service))
        #expect(await service.snapshot.backendState == .registered)
        #expect(await PushRegistrationURLProtocol.script.requests.count == 2)
    }

    @Test func metadataFreeRateLimitUsesConfiguredBackoff() async {
        await PushRegistrationURLProtocol.script.reset([
            .response(429, json: #"{"error":"rate_limited"}"#),
            .response(200),
        ])
        let delays = RetryDelayRecorder()
        let (service, _) = makeScriptedService(
            retryDelays: [.seconds(30)],
            retrySleep: { duration in
                await delays.record(duration)
            }
        )

        await service.register(deviceToken: Data(repeating: 0xAB, count: 32))
        await service.setEnabled(true)
        #expect(
            await PushRegistrationURLProtocol.script.waitForRequestCount(2)
        )
        #expect(await wait(for: .registered, from: service))

        #expect(await delays.values.first == .seconds(30))
        #expect(await PushRegistrationURLProtocol.script.requests.count == 2)
    }

    @Test func deviceCap429IsPermanentAndActionableWithoutRetry() async {
        await PushRegistrationURLProtocol.script.reset([
            .response(
                429,
                json: #"{"error":"too_many_devices","limit":200}"#
            ),
            .response(200),
        ])
        let (service, _) = makeScriptedService(retryDelays: [.zero])

        await service.register(deviceToken: Data(repeating: 0xAB, count: 32))
        await service.setEnabled(true)

        #expect(
            await service.snapshot.backendState
                == .failed(.deviceLimitReached(limit: 200))
        )
        #expect(await PushRegistrationURLProtocol.script.requests.count == 1)
    }

    @Test(arguments: ["", "not-json", #"{"error":"future"}"#])
    func malformedOrMissing429BodyRemainsAConventionalRetryableRateLimit(
        body: String
    ) async {
        await PushRegistrationURLProtocol.script.reset([
            .response(429, headers: ["Retry-After": "0"], json: body),
            .response(200),
        ])
        let (service, _) = makeScriptedService(retryDelays: [.zero])

        await service.register(deviceToken: Data(repeating: 0xAB, count: 32))
        await service.setEnabled(true)
        #expect(
            await PushRegistrationURLProtocol.script.waitForRequestCount(2)
        )
        #expect(await wait(for: .registered, from: service))

        #expect(await service.snapshot.backendState == .registered)
        #expect(await PushRegistrationURLProtocol.script.requests.count == 2)
    }

    @Test func networkFailureIsVisibleWhileRetryIsPending() async {
        await PushRegistrationURLProtocol.script.reset([.failure(.notConnectedToInternet)])
        let (service, _) = makeScriptedService(retryDelays: [.seconds(60)])

        await service.register(deviceToken: Data(repeating: 0xAB, count: 32))
        await service.setEnabled(true)

        #expect(await service.snapshot.backendState == .failed(.networkUnavailable))
        #expect(await service.snapshot.backendState.isRecoverable)
    }

    @Test func apnsTokenCallbackFailureIsActionableAndSuccessfulRetryRecovers() async {
        await PushRegistrationURLProtocol.script.reset([.response(200)])
        let (service, _) = makeScriptedService()

        await service.setEnabled(true)
        await service.deviceTokenRegistrationFailed()

        #expect(
            await service.snapshot.backendState
                == .deviceTokenRegistrationFailed
        )

        await service.register(deviceToken: Data(repeating: 0xCD, count: 32))

        #expect(await service.snapshot.backendState == .registered)
    }

    @Test func disablingCancelsPendingRetryAndClearsReadiness() async {
        await PushRegistrationURLProtocol.script.reset([
            .response(503),
            .response(200),
        ])
        let (service, _) = makeScriptedService(retryDelays: [.seconds(60)])

        await service.register(deviceToken: Data(repeating: 0xAB, count: 32))
        await service.setEnabled(true)
        await service.setEnabled(false)

        #expect(await service.snapshot == .disabled)
    }

    @Test func offlineOptOutRetriesDeleteForTheSameAccountAfterRelaunch() async {
        await PushRegistrationURLProtocol.script.reset([
            .response(200),
            .failure(.notConnectedToInternet),
            .response(200),
        ])
        let suite = "push-optout-retry-\(UUID().uuidString)"
        let (service, _) = makeScriptedService(suite: suite)
        await service.register(deviceToken: Data(repeating: 0xAB, count: 32))
        await service.setEnabled(true)
        await service.setEnabled(false)

        let (relaunched, _) = makeScriptedService(suite: suite)
        await relaunched.syncTokenIfPossible()

        let methods = await PushRegistrationURLProtocol.script.requests
            .map(\.httpMethod)
        #expect(methods == ["POST", "DELETE", "DELETE"])
        #expect(await relaunched.snapshot == .disabled)
    }

    @Test func optOutWithoutLiveSessionPersistsOwnerBeforeAuthentication() async {
        await PushRegistrationURLProtocol.script.reset([.response(200)])
        let suite = "push-optout-no-session-\(UUID().uuidString)"
        let (service, defaults) = makeScriptedService(
            tokenProvider: FakeTokenProvider(access: nil, refresh: nil),
            suite: suite,
            accountID: nil
        )
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")
        defaults.set("ab", forKey: "cmux.notifications.deviceTokenHex")
        defaults.set("account-a", forKey: "cmux.notifications.registeredAccountID")

        await service.setEnabled(false)

        #expect(pendingUnregisters(
            suite: suite,
            accountID: "account-a"
        ) == [PendingUnregister(tokenHex: "ab", accountID: "account-a")])
        #expect(await PushRegistrationURLProtocol.script.requests.isEmpty)

        let (returned, _) = makeScriptedService(
            tokenProvider: FakeTokenProvider(
                access: "a-returned",
                refresh: "a-returned-refresh"
            ),
            suite: suite,
            accountID: "account-a"
        )
        await returned.syncTokenIfPossible()

        #expect(
            await PushRegistrationURLProtocol.script.requests.last?
                .value(forHTTPHeaderField: "Authorization")
                == "Bearer a-returned"
        )
        #expect(
            defaults.data(forKey: "cmux.notifications.pendingUnregisters.v2")
                == nil
        )
    }

    @Test func relaunchRecoversOptOutCommittedBeforeServiceHandoff() async {
        await PushRegistrationURLProtocol.script.reset([.response(200)])
        let (service, _) = makeScriptedService(
            seedDefaults: { defaults in
                defaults.set(false, forKey: "cmux.notifications.pushEnabled")
                defaults.set("ab", forKey: "cmux.notifications.deviceTokenHex")
                defaults.set(
                    "push-user-1",
                    forKey: "cmux.notifications.registeredAccountID"
                )
            }
        )

        _ = await service.snapshots()
        await PushRegistrationURLProtocol.script.waitForRequestCount(1)

        #expect(
            await PushRegistrationURLProtocol.script.requests.map(\.httpMethod)
                == ["DELETE"]
        )
    }

    @Test func accountBOwnedOptOutNeverDeletesAccountATokenWithBCredentials() async {
        await PushRegistrationURLProtocol.script.reset([.response(200)])
        let suite = "push-optout-owner-mismatch-\(UUID().uuidString)"
        let (service, defaults) = makeScriptedService(
            tokenProvider: FakeTokenProvider(
                access: "b-access",
                refresh: "b-refresh"
            ),
            suite: suite,
            accountID: "account-b"
        )
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")
        defaults.set("aa", forKey: "cmux.notifications.deviceTokenHex")
        defaults.set("account-a", forKey: "cmux.notifications.registeredAccountID")

        await service.setEnabled(false)

        #expect(await PushRegistrationURLProtocol.script.requests.isEmpty)
        #expect(pendingUnregisters(
            suite: suite,
            accountID: "account-a"
        ) == [PendingUnregister(tokenHex: "aa", accountID: "account-a")])
        #expect(pendingUnregisters(
            suite: suite,
            accountID: "account-b"
        ).isEmpty)
    }

    @Test func malformedDeleteAcknowledgementKeepsDurableTombstone() async {
        await PushRegistrationURLProtocol.script.reset([
            .response(200, json: ""),
        ])
        let suite = "push-delete-ack-\(UUID().uuidString)"
        let (service, defaults) = makeScriptedService(
            suite: suite,
            accountID: "account-a"
        )
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")
        defaults.set("ab", forKey: "cmux.notifications.deviceTokenHex")
        defaults.set("account-a", forKey: "cmux.notifications.registeredAccountID")

        await service.setEnabled(false)

        #expect(pendingUnregisters(
            suite: suite,
            accountID: "account-a"
        ) == [PendingUnregister(tokenHex: "ab", accountID: "account-a")])
        #expect(
            defaults.string(forKey: "cmux.notifications.registeredAccountID")
                == "account-a"
        )

        await PushRegistrationURLProtocol.script.reset([.response(200)])
        let (returned, _) = makeScriptedService(
            suite: suite,
            accountID: "account-a"
        )
        await returned.syncTokenIfPossible()
        #expect(
            defaults.data(forKey: "cmux.notifications.pendingUnregisters.v2")
                == nil
        )
    }

    @Test func disablingDuringInFlightRegistrationDeletesAfterLatePost() async {
        let started = TestPhaseSignal()
        let blocker = TestContinuationBlocker()
        await PushRegistrationURLProtocol.script.reset([
            .gatedResponse(200, started: started, blocker: blocker),
            .response(200),
            .response(200),
        ])
        let provider = MutablePushTokenProvider(
            accountID: "account-a",
            accessToken: "a-access",
            refreshToken: "a-refresh"
        )
        let (service, defaults) = makeScriptedService(
            tokenProvider: provider,
            accountID: nil
        )
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")

        let upload = Task {
            await service.register(deviceToken: Data([0xAA]))
        }
        await started.waitUntilStarted()
        await service.setEnabled(false)
        await blocker.release()
        await upload.value

        let requests = await PushRegistrationURLProtocol.script.requests
        #expect(requests.map(\.httpMethod) == ["POST", "DELETE", "DELETE"])
        #expect(
            requests.map {
                $0.value(forHTTPHeaderField: "Authorization")
            } == [
                "Bearer a-access",
                "Bearer a-access",
                "Bearer a-access",
            ]
        )
        #expect(
            defaults.data(
                forKey: "cmux.notifications.pendingUnregisters.v2"
            ) == nil
        )
    }

    @Test func enablingDuringInFlightDisableRepostsAfterLateDelete() async {
        let started = TestPhaseSignal()
        let blocker = TestContinuationBlocker()
        await PushRegistrationURLProtocol.script.reset([
            .response(200),
            .gatedResponse(200, started: started, blocker: blocker),
            .response(200),
            .response(200),
        ])
        let (service, _) = makeScriptedService()
        await service.register(deviceToken: Data([0xAA]))
        await service.setEnabled(true)

        let disabling = Task {
            await service.setEnabled(false)
        }
        await started.waitUntilStarted()
        await service.setEnabled(true)
        await blocker.release()
        await disabling.value

        #expect(
            await PushRegistrationURLProtocol.script.requests.map(\.httpMethod)
                == ["POST", "DELETE", "POST", "POST"]
        )
        #expect(await service.snapshot.backendState == .registered)
    }

    @Test func coordinatorIntentWorkerDrainsLatestOptOutAfterLatePost() async {
        let started = TestPhaseSignal()
        let blocker = TestContinuationBlocker()
        await PushRegistrationURLProtocol.script.reset([
            .gatedResponse(200, started: started, blocker: blocker),
            .response(200),
            .response(200),
        ])
        let suite = "push-ambiguous-post-\(UUID().uuidString)"
        let (service, _) = makeScriptedService(suite: suite)
        await service.register(deviceToken: Data([0xAA]))

        await service.applyEnabledIntent(true, generation: 1)
        await service.reconcileEnabledIntent(generation: 1)
        await started.waitUntilStarted()
        #expect(pendingUnregisters(
            suite: suite,
            accountID: "push-user-1"
        ) == [PendingUnregister(
            tokenHex: "aa",
            accountID: "push-user-1"
        )])
        await service.applyEnabledIntent(false, generation: 2)

        // Opt-out cleanup must start while the superseded POST is still
        // parked. Waiting for that POST could leave the backend token active
        // indefinitely even though the UI already reports notifications off.
        #expect(
            await PushRegistrationURLProtocol.script.waitForRequestCount(2)
        )
        #expect(
            await PushRegistrationURLProtocol.script.requests.map(\.httpMethod)
                == ["POST", "DELETE"]
        )
        #expect(await service.snapshot == .disabled)

        await blocker.release()
        await PushRegistrationURLProtocol.script.waitForRequestCount(3)

        #expect(
            await PushRegistrationURLProtocol.script.requests.map(\.httpMethod)
                == ["POST", "DELETE", "DELETE"]
        )
        #expect(await service.snapshot == .disabled)
    }

    @Test func coordinatorIntentAuthenticationHasBoundedSingleAttempt() async {
        let started = TestPhaseSignal()
        let blocker = TestContinuationBlocker()
        let provider = CancellationIgnoringPushTokenProvider(
            started: started,
            blocker: blocker
        )
        let clock = ManualTestClock()
        let timeout = Duration.seconds(2)
        let (service, _) = makeScriptedService(
            tokenProvider: provider,
            accountID: nil,
            sessionSnapshotTimeout: timeout,
            sessionSnapshotClock: clock
        )
        await service.register(deviceToken: Data([0xAA]))

        await service.applyEnabledIntent(true, generation: 1)
        await service.reconcileEnabledIntent(generation: 1)
        await started.waitUntilStarted()
        await clock.waitUntilSleepers()
        clock.advance(by: timeout)

        #expect(
            await wait(
                for: .failed(.authenticationRequired),
                from: service
            )
        )

        // The timed-out provider deliberately ignores cancellation. A newer
        // enable intent fails against the active phase instead of accumulating
        // another unowned task behind it.
        await service.applyEnabledIntent(true, generation: 2)
        await service.reconcileEnabledIntent(generation: 2)
        #expect(
            await wait(
                for: .failed(.authenticationRequired),
                from: service
            )
        )
        await provider.waitUntilCancellationObserved()
        #expect(await provider.snapshotRequestCount == 1)

        await blocker.release()
        await provider.waitUntilCompleted()
    }

    @Test func coordinatorOptOutAuthenticationHasBoundedSingleAttempt() async {
        let started = TestPhaseSignal()
        let blocker = TestContinuationBlocker()
        let provider = CancellationIgnoringPushTokenProvider(
            started: started,
            blocker: blocker
        )
        let clock = ManualTestClock()
        let timeout = Duration.seconds(2)
        let (service, _) = makeScriptedService(
            tokenProvider: provider,
            accountID: nil,
            seedDefaults: { defaults in
                defaults.set(
                    true,
                    forKey: "cmux.notifications.pushEnabled"
                )
                defaults.set(
                    "aa",
                    forKey: "cmux.notifications.deviceTokenHex"
                )
                defaults.set(
                    "push-user-1",
                    forKey: "cmux.notifications.registeredAccountID"
                )
            },
            sessionSnapshotTimeout: timeout,
            sessionSnapshotClock: clock
        )

        let disabling = Task {
            await service.applyEnabledIntent(false, generation: 1)
        }
        await started.waitUntilStarted()
        await clock.waitUntilSleepers()
        clock.advance(by: timeout)
        await provider.waitUntilCancellationObserved()
        await disabling.value

        // A direct cleanup retry must fail against the still-active timed-out
        // phase instead of starting a second authentication operation.
        await service.unregisterFromServer()
        #expect(await provider.snapshotRequestCount == 1)
        #expect(await service.snapshot == .disabled)

        await blocker.release()
        await provider.waitUntilCompleted()
    }

    @Test func signOutDuringInFlightRegistrationDeletesAfterLatePost() async {
        let started = TestPhaseSignal()
        let blocker = TestContinuationBlocker()
        await PushRegistrationURLProtocol.script.reset([
            .gatedResponse(200, started: started, blocker: blocker),
            .response(200),
            .response(200),
        ])
        let provider = MutablePushTokenProvider(
            accountID: "account-a",
            accessToken: "a-live-access",
            refreshToken: "a-live-refresh"
        )
        let (service, defaults) = makeScriptedService(
            tokenProvider: provider,
            accountID: nil
        )
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")
        defaults.set(
            "account-a",
            forKey: "cmux.notifications.registeredAccountID"
        )

        let upload = Task {
            await service.register(deviceToken: Data([0xAA]))
        }
        await started.waitUntilStarted()
        await provider.clearSession()
        await service.unregisterFromServer(
            accountID: "account-a",
            accessToken: "a-captured-access",
            refreshToken: "a-captured-refresh"
        )
        await blocker.release()
        await upload.value

        let requests = await PushRegistrationURLProtocol.script.requests
        #expect(requests.map(\.httpMethod) == ["POST", "DELETE", "DELETE"])
        #expect(
            requests.map {
                $0.value(forHTTPHeaderField: "Authorization")
            } == [
                "Bearer a-live-access",
                "Bearer a-captured-access",
                "Bearer a-live-access",
            ]
        )
        #expect(
            defaults.data(
                forKey: "cmux.notifications.pendingUnregisters.v2"
            ) == nil
        )
    }

    @Test func oldAccountLatePostCannotTakeTokenBackFromNewAccount() async {
        let started = TestPhaseSignal()
        let blocker = TestContinuationBlocker()
        await PushRegistrationURLProtocol.script.reset([
            .gatedResponse(200, started: started, blocker: blocker),
            .response(200),
            .response(200),
            .response(200),
        ])
        let provider = MutablePushTokenProvider(
            accountID: "account-a",
            accessToken: "a-access",
            refreshToken: "a-refresh"
        )
        let (service, defaults) = makeScriptedService(
            tokenProvider: provider,
            accountID: nil
        )
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")

        let oldUpload = Task {
            await service.register(deviceToken: Data([0xAA]))
        }
        await started.waitUntilStarted()
        await provider.switchSession(
            accountID: "account-b",
            accessToken: "b-access",
            refreshToken: "b-refresh"
        )
        let currentSync = Task {
            await service.syncTokenIfPossible()
        }
        await blocker.release()
        await oldUpload.value
        await currentSync.value

        let requests = await PushRegistrationURLProtocol.script.requests
        #expect(
            requests.map(\.httpMethod)
                == ["POST", "DELETE", "POST"]
        )
        #expect(
            requests.map {
                $0.value(forHTTPHeaderField: "Authorization")
            } == [
                "Bearer a-access",
                "Bearer a-access",
                "Bearer b-access",
            ]
        )
        #expect(
            defaults.string(
                forKey: "cmux.notifications.registeredAccountID"
            ) == "account-b"
        )
        #expect(await service.snapshot.backendState == .registered)
    }

    @Test func pendingOldAccountDeleteNeverUsesNextAccountsCredentials() async {
        await PushRegistrationURLProtocol.script.reset([
            .failure(.notConnectedToInternet),
            .response(200),
        ])
        let suite = "push-account-switch-\(UUID().uuidString)"
        let (oldService, defaults) = makeScriptedService(
            tokenProvider: FakeTokenProvider(access: "old-access", refresh: "old-refresh"),
            suite: suite,
            accountID: "old-user"
        )
        defaults.set("ab", forKey: "cmux.notifications.deviceTokenHex")
        await oldService.unregisterFromServer(
            accessToken: "old-access",
            refreshToken: "old-refresh"
        )

        let (nextService, _) = makeScriptedService(
            tokenProvider: FakeTokenProvider(access: "next-access", refresh: "next-refresh"),
            suite: suite,
            accountID: "next-user"
        )
        await nextService.syncTokenIfPossible()

        #expect(await PushRegistrationURLProtocol.script.requests.count == 1)
        #expect(
            await PushRegistrationURLProtocol.script.requests.first?
                .value(forHTTPHeaderField: "Authorization")
                == "Bearer old-access"
        )
    }

    @Test func pendingOldAccountDeleteCompletesWhenThatAccountSignsInAgain() async {
        await PushRegistrationURLProtocol.script.reset([
            .failure(.notConnectedToInternet),
            .response(200),
        ])
        let suite = "push-old-account-return-\(UUID().uuidString)"
        let (oldService, defaults) = makeScriptedService(
            tokenProvider: FakeTokenProvider(access: "old-access", refresh: "old-refresh"),
            suite: suite,
            accountID: "old-user"
        )
        defaults.set("ab", forKey: "cmux.notifications.deviceTokenHex")
        defaults.set("old-user", forKey: "cmux.notifications.registeredAccountID")
        await oldService.unregisterFromServer(
            accountID: "old-user",
            accessToken: "old-access",
            refreshToken: "old-refresh"
        )

        let (returnedService, _) = makeScriptedService(
            tokenProvider: FakeTokenProvider(access: "returned-access", refresh: "returned-refresh"),
            suite: suite,
            accountID: "old-user"
        )
        await returnedService.syncTokenIfPossible()

        #expect(await PushRegistrationURLProtocol.script.requests.count == 2)
        #expect(
            await PushRegistrationURLProtocol.script.requests.last?
                .value(forHTTPHeaderField: "Authorization")
                == "Bearer returned-access"
        )
    }

    @Test func sessionSwitchDuringUploadRepairsBackendForNewAccount() async {
        let started = TestPhaseSignal()
        let blocker = TestContinuationBlocker()
        await PushRegistrationURLProtocol.script.reset([
            .gatedResponse(200, started: started, blocker: blocker),
            .response(200),
            .response(200),
        ])
        let provider = MutablePushTokenProvider(
            accountID: "account-a",
            accessToken: "a-access",
            refreshToken: "a-refresh"
        )
        let (service, defaults) = makeScriptedService(
            tokenProvider: provider,
            accountID: nil
        )
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")

        let upload = Task {
            await service.register(deviceToken: Data([0xAA]))
        }
        await started.waitUntilStarted()
        await provider.switchSession(
            accountID: "account-b",
            accessToken: "b-access",
            refreshToken: "b-refresh"
        )
        await blocker.release()
        await upload.value

        #expect(await service.snapshot.backendState == .registered)
        #expect(
            defaults.string(forKey: "cmux.notifications.registeredAccountID")
                == "account-b"
        )
        #expect(
            await PushRegistrationURLProtocol.script.requests
                .map(\.httpMethod) == ["POST", "DELETE", "POST"]
        )
    }

    @Test func sessionSwitchDuringDeleteCannotClearOldAccountTombstone() async {
        let started = TestPhaseSignal()
        let blocker = TestContinuationBlocker()
        await PushRegistrationURLProtocol.script.reset([
            .gatedResponse(200, started: started, blocker: blocker),
        ])
        let provider = MutablePushTokenProvider(
            accountID: "account-a",
            accessToken: "a-access",
            refreshToken: "a-refresh"
        )
        let suite = "push-delete-session-switch-\(UUID().uuidString)"
        let (service, defaults) = makeScriptedService(
            tokenProvider: provider,
            suite: suite,
            accountID: nil
        )
        defaults.set(
            try? JSONEncoder().encode([[
                "tokenHex": "aa",
                "accountID": "account-a",
            ]]),
            forKey: "cmux.notifications.pendingUnregisters.v2"
        )

        let cleanup = Task { await service.syncTokenIfPossible() }
        await started.waitUntilStarted()
        await provider.switchSession(
            accountID: "account-b",
            accessToken: "b-access",
            refreshToken: "b-refresh"
        )
        await blocker.release()
        await cleanup.value

        let queueText = defaults.data(
            forKey: "cmux.notifications.pendingUnregisters.v2"
        ).flatMap { String(data: $0, encoding: .utf8) }
        #expect(queueText?.contains("account-a") == true)
    }

    @Test func tokenRotationRegistersNewTokenBeforeDurableOldTokenCleanup() async {
        await PushRegistrationURLProtocol.script.reset([
            .response(200),
            .failure(.notConnectedToInternet),
        ])
        let suite = "push-token-rotation-\(UUID().uuidString)"
        let (service, defaults) = makeScriptedService(
            suite: suite,
            accountID: "account-a"
        )
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")
        defaults.set("aa", forKey: "cmux.notifications.deviceTokenHex")
        defaults.set("account-a", forKey: "cmux.notifications.registeredAccountID")

        await service.register(deviceToken: Data([0xBB]))

        let firstRequests = await PushRegistrationURLProtocol.script.requests
        #expect(firstRequests.map(\.httpMethod) == ["POST", "DELETE"])
        #expect(await service.snapshot.backendState == .registered)
        #expect(pendingUnregisters(
            suite: suite,
            accountID: "account-a"
        ) == [PendingUnregister(tokenHex: "aa", accountID: "account-a")])

        await PushRegistrationURLProtocol.script.reset([
            .response(200),
            .response(200),
        ])
        let (relaunched, _) = makeScriptedService(
            suite: suite,
            accountID: "account-a"
        )
        await relaunched.syncTokenIfPossible()
        let recoveredRequests = await PushRegistrationURLProtocol.script.requests
        #expect(recoveredRequests.map(\.httpMethod) == ["POST", "DELETE"])
        let bodies = await PushRegistrationURLProtocol.script.requestBodies
            .compactMap { data -> String? in
            guard let data,
                  let body = try? JSONSerialization.jsonObject(with: data)
                    as? [String: String] else { return nil }
            return body["deviceToken"]
        }
        #expect(bodies == ["bb", "aa"])
    }

    @Test func sameAccountTokenRotationRetainsNewTokenOwnership() async {
        await PushRegistrationURLProtocol.script.reset([
            .response(200),
            .response(200),
        ])
        let (service, defaults) = makeScriptedService(
            accountID: "account-a"
        )
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")
        defaults.set("aa", forKey: "cmux.notifications.deviceTokenHex")
        defaults.set(
            "account-a",
            forKey: "cmux.notifications.registeredAccountID"
        )

        await service.register(deviceToken: Data([0xBB]))

        #expect(
            await PushRegistrationURLProtocol.script.requests
                .map(\.httpMethod) == ["POST", "DELETE"]
        )
        #expect(
            defaults.string(
                forKey: "cmux.notifications.registeredAccountID"
            ) == "account-a"
        )
        #expect(
            defaults.data(
                forKey: "cmux.notifications.pendingUnregisters.v2"
            ) == nil
        )
    }

    @Test func repeatedSameDeviceTokenDoesNotQueueDuplicateDelete() async {
        await PushRegistrationURLProtocol.script.reset([.response(200)])
        let (service, defaults) = makeScriptedService(accountID: "account-a")
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")
        defaults.set("ab", forKey: "cmux.notifications.deviceTokenHex")
        defaults.set("account-a", forKey: "cmux.notifications.registeredAccountID")

        await service.register(deviceToken: Data([0xAB]))

        #expect(
            await PushRegistrationURLProtocol.script.requests
                .map(\.httpMethod)
                == ["POST"]
        )
        #expect(
            defaults.data(forKey: "cmux.notifications.pendingUnregisters.v2")
                == nil
        )
    }

    @Test func offlineAccountSwitchKeepsBothAccountScopedTombstones() async {
        await PushRegistrationURLProtocol.script.reset([
            .failure(.notConnectedToInternet),
            .failure(.notConnectedToInternet),
            .response(200),
            .response(200),
        ])
        let suite = "push-two-account-tombstones-\(UUID().uuidString)"
        let (accountA, defaults) = makeScriptedService(
            tokenProvider: FakeTokenProvider(access: "a-access", refresh: "a-refresh"),
            suite: suite,
            accountID: "account-a"
        )
        defaults.set("aa", forKey: "cmux.notifications.deviceTokenHex")
        defaults.set("account-a", forKey: "cmux.notifications.registeredAccountID")
        await accountA.unregisterFromServer(
            accountID: "account-a",
            accessToken: "a-access",
            refreshToken: "a-refresh"
        )

        defaults.set("bb", forKey: "cmux.notifications.deviceTokenHex")
        defaults.set("account-b", forKey: "cmux.notifications.registeredAccountID")
        let (accountB, _) = makeScriptedService(
            tokenProvider: FakeTokenProvider(access: "b-access", refresh: "b-refresh"),
            suite: suite,
            accountID: "account-b"
        )
        await accountB.unregisterFromServer(
            accountID: "account-b",
            accessToken: "b-access",
            refreshToken: "b-refresh"
        )

        let (returnedA, _) = makeScriptedService(
            tokenProvider: FakeTokenProvider(
                access: "a-returned",
                refresh: "a-returned-refresh"
            ),
            suite: suite,
            accountID: "account-a"
        )
        await returnedA.syncTokenIfPossible()
        let (returnedB, _) = makeScriptedService(
            tokenProvider: FakeTokenProvider(
                access: "b-returned",
                refresh: "b-returned-refresh"
            ),
            suite: suite,
            accountID: "account-b"
        )
        await returnedB.syncTokenIfPossible()

        let requests = await PushRegistrationURLProtocol.script.requests
        #expect(requests.map(\.httpMethod) == ["DELETE", "DELETE", "DELETE", "DELETE"])
        #expect(
            requests.map {
                $0.value(forHTTPHeaderField: "Authorization")
            } == [
                "Bearer a-access",
                "Bearer b-access",
                "Bearer a-returned",
                "Bearer b-returned",
            ]
        )
        let deletedTokens = await PushRegistrationURLProtocol.script
            .requestBodies.compactMap { body -> String? in
            guard let body,
                  let object = try? JSONSerialization.jsonObject(with: body)
                    as? [String: String] else { return nil }
            return object["deviceToken"]
        }
        #expect(deletedTokens == ["aa", "bb", "aa", "bb"])
    }

    @Test func pendingCleanupMigrationMovesEveryEntryToIndexedStore() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("push-overflow-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let existing = (0..<200).map { index in
            [
                "tokenHex": String(format: "%064x", index),
                "accountID": "historical-account-\(index)",
            ]
        }
        let (service, defaults) = makeScriptedService(
            accountID: nil,
            seedDefaults: { defaults in
                defaults.set(
                    try? JSONSerialization.data(withJSONObject: existing),
                    forKey: "cmux.notifications.pendingUnregisters.v2"
                )
                defaults.set(
                    true,
                    forKey: "cmux.notifications.pushEnabled"
                )
                defaults.set(
                    String(repeating: "f", count: 64),
                    forKey: "cmux.notifications.deviceTokenHex"
                )
                defaults.set(
                    "current-account",
                    forKey: "cmux.notifications.registeredAccountID"
                )
            },
            pendingUnregisterStoreURL: storeURL
        )

        await service.applyEnabledIntent(false, generation: 1)

        #expect(defaults.data(
            forKey: "cmux.notifications.pendingUnregisters.v2"
        ) == nil)
        let store = try PendingUnregisterStore(databaseURL: storeURL)
        let oldest = store.batch(
            accountID: "historical-account-0",
            limit: 2
        )
        let newest = store.batch(accountID: "current-account", limit: 2)
        #expect(oldest.map(\.accountID) == ["historical-account-0"])
        #expect(newest.map(\.accountID) == ["current-account"])
    }

    @Test func durableCleanupStoreReopensAfterLaunchFailure() async throws {
        await PushRegistrationURLProtocol.script.reset([.response(200)])
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "push-store-reopen-\(UUID().uuidString)",
            isDirectory: true
        )
        let parkedRoot = root.appendingPathExtension("parked")
        let storeURL = root.appendingPathComponent("cleanup.sqlite3")
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: parkedRoot)
        }
        do {
            let store = try PendingUnregisterStore(databaseURL: storeURL)
            #expect(store.insert(PendingUnregister(
                tokenHex: "aa",
                accountID: "account-a"
            )))
        }
        try fileManager.moveItem(at: root, to: parkedRoot)
        #expect(fileManager.createFile(atPath: root.path, contents: Data()))

        let (service, _) = makeScriptedService(
            accountID: "account-a",
            pendingUnregisterStoreURL: storeURL
        )

        try fileManager.removeItem(at: root)
        try fileManager.moveItem(at: parkedRoot, to: root)
        _ = await service.snapshots()
        #expect(
            await PushRegistrationURLProtocol.script.waitForRequestCount(1)
        )
        #expect(
            await PushRegistrationURLProtocol.script.requests.map(\.httpMethod)
                == ["DELETE"]
        )
        let reopenedStore = try PendingUnregisterStore(databaseURL: storeURL)
        var cleanupFinished = false
        for _ in 0..<1_000 {
            if reopenedStore.batch(accountID: "account-a", limit: 2).isEmpty {
                cleanupFinished = true
                break
            }
            await Task.yield()
        }
        #expect(cleanupFinished)
    }

    @Test func successfulReassignmentClearsOldTombstoneWithoutLosingNewOwner() async throws {
        await PushRegistrationURLProtocol.script.reset([.response(200)])
        let suite = "push-owner-reassignment-\(UUID().uuidString)"
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("push-owner-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let overflowStore = try PendingUnregisterStore(databaseURL: storeURL)
        #expect(overflowStore.insert(PendingUnregister(
            tokenHex: "ab",
            accountID: "old-user"
        )))
        let (service, defaults) = makeScriptedService(
            tokenProvider: FakeTokenProvider(
                access: "new-access",
                refresh: "new-refresh"
            ),
            suite: suite,
            accountID: "new-user",
            seedDefaults: { defaults in
                defaults.set("ab", forKey: "cmux.notifications.deviceTokenHex")
                defaults.set(
                    "old-user",
                    forKey: "cmux.notifications.registeredAccountID"
                )
                defaults.set(
                    "ab",
                    forKey: "cmux.notifications.pendingUnregisterToken"
                )
                defaults.set(
                    "old-user",
                    forKey: "cmux.notifications.pendingUnregisterAccountID"
                )
            },
            pendingUnregisterStoreURL: storeURL
        )

        await service.setEnabled(true)

        #expect(
            defaults.string(forKey: "cmux.notifications.registeredAccountID")
                == "new-user"
        )
        #expect(
            defaults.data(forKey: "cmux.notifications.pendingUnregisters.v2")
                == nil
        )
        #expect(
            defaults.string(forKey: "cmux.notifications.pendingUnregisterAccountID")
                == nil
        )
        #expect(!overflowStore.hasEntries)
    }

    @Test func legacySingleTombstoneMigratesOnceAndIsRemovedAfterSuccess() async {
        await PushRegistrationURLProtocol.script.reset([.response(200)])
        let suite = "push-legacy-tombstone-\(UUID().uuidString)"
        let (service, defaults) = makeScriptedService(
            tokenProvider: FakeTokenProvider(
                access: "returned-access",
                refresh: "returned-refresh"
            ),
            suite: suite,
            accountID: "old-user",
            seedDefaults: { defaults in
                defaults.set(
                    "ab",
                    forKey: "cmux.notifications.pendingUnregisterToken"
                )
                defaults.set(
                    "old-user",
                    forKey: "cmux.notifications.pendingUnregisterAccountID"
                )
            }
        )

        await service.syncTokenIfPossible()

        #expect(await PushRegistrationURLProtocol.script.requests.count == 1)
        #expect(
            defaults.string(forKey: "cmux.notifications.pendingUnregisterToken")
                == nil
        )
        #expect(
            defaults.string(forKey: "cmux.notifications.pendingUnregisterAccountID")
                == nil
        )
        #expect(
            defaults.data(forKey: "cmux.notifications.pendingUnregisters.v2")
                == nil
        )
    }

    @Test func disableIsIdempotentAfterUnregisterSucceeds() async {
        await PushRegistrationURLProtocol.script.reset([
            .response(200),
            .response(200),
        ])
        let (service, _) = makeScriptedService()
        await service.register(deviceToken: Data(repeating: 0xAB, count: 32))
        await service.setEnabled(true)
        await service.setEnabled(false)
        await service.setEnabled(false)

        #expect(
            await PushRegistrationURLProtocol.script.requests
                .filter { $0.httpMethod == "DELETE" }
                .count
                == 1
        )
    }

    private func makeRedirectService(
        scenario: PushRedirectURLProtocol.Scenario
    ) async -> PushRegistrationService {
        await PushRedirectURLProtocol.state.reset(scenario)
        let suite = "push-redirect-\(UUID().uuidString)"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PushRedirectURLProtocol.self]
        return PushRegistrationService(
            tokenProvider: FakeTokenProvider(),
            apiBaseURL: "https://\(PushRedirectURLProtocol.startHost)",
            bundleID: "dev.cmux.ios.push1",
            apnsEnvironment: "sandbox",
            suiteName: suite,
            session: URLSession(configuration: configuration),
            retryDelays: []
        )
    }

    @Test(arguments: [
        PushRedirectURLProtocol.Scenario.sameOrigin301,
        .sameOrigin302,
        .sameOrigin307,
        .sameOrigin308,
    ])
    func sameOriginRedirectsPreserveRegistrationMethodBodyAndCredentials(
        scenario: PushRedirectURLProtocol.Scenario
    ) async throws {
        let service = await makeRedirectService(scenario: scenario)
        await service.register(deviceToken: Data(repeating: 0xAB, count: 32))
        await service.setEnabled(true)

        let target = try #require(await PushRedirectURLProtocol.state.targetRequests.first)
        #expect(target.httpMethod == "POST")
        #expect(target.httpBody != nil || target.httpBodyStream != nil)
        #expect(target.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        #expect(target.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == "refresh")
    }

    @Test func sameOrigin303FailsVisiblyWithoutSendingAFalseAcknowledgement() async {
        let service = await makeRedirectService(scenario: .sameOrigin303)

        await service.register(deviceToken: Data(repeating: 0xAB, count: 32))
        await service.setEnabled(true)

        #expect(await PushRedirectURLProtocol.state.targetRequests.isEmpty)
        #expect(
            await service.snapshot.backendState
                == .failed(.invalidServerResponse)
        )
    }

    @Test(arguments: [
        PushRedirectURLProtocol.Scenario.schemeDowngrade307,
        .crossHost308,
        .portChange302,
    ])
    func originChangesFailClosedBeforeSendingTokenOrCustomCredentials(
        scenario: PushRedirectURLProtocol.Scenario
    ) async {
        let service = await makeRedirectService(scenario: scenario)

        await service.register(deviceToken: Data(repeating: 0xAB, count: 32))
        await service.setEnabled(true)

        #expect(await PushRedirectURLProtocol.state.targetRequests.isEmpty)
    }
}
