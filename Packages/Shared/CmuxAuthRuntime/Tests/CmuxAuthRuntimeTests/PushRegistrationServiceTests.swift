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
    private var snapshotBlocker: TestContinuationBlocker?
    private var snapshotStarted: TestPhaseSignal?

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

    func blockAuthenticatedSessionSnapshot(
        started: TestPhaseSignal,
        until blocker: TestContinuationBlocker
    ) {
        snapshotStarted = started
        snapshotBlocker = blocker
    }

    func authenticatedSessionSnapshot() async throws
        -> AuthenticatedSessionSnapshot {
        if let blocker = snapshotBlocker {
            snapshotBlocker = nil
            let started = snapshotStarted
            snapshotStarted = nil
            await started?.markStarted()
            await blocker.wait()
        }
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
        }
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
            session: URLSession(configuration: configuration),
            retryDelays: retryDelays,
            retryJitter: { _ in 1 },
            retrySleep: retrySleep
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

        let queueData = defaults.data(
            forKey: "cmux.notifications.pendingUnregisters.v2"
        )
        let queue = queueData.flatMap {
            try? JSONSerialization.jsonObject(with: $0)
                as? [[String: String]]
        }
        #expect(queue == [["tokenHex": "ab", "accountID": "old-user"]])
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

    @Test func cancelledQueuedSignOutStillPersistsCleanupObligation() async {
        await PushRegistrationURLProtocol.script.reset([])
        let provider = MutablePushTokenProvider(
            accountID: "account-a",
            accessToken: "a-access",
            refreshToken: "a-refresh"
        )
        let started = TestPhaseSignal()
        let blocker = TestContinuationBlocker()
        await provider.blockAuthenticatedSessionSnapshot(
            started: started,
            until: blocker
        )
        let (service, defaults) = makeScriptedService(
            tokenProvider: provider,
            accountID: nil
        )
        defaults.set("ab", forKey: "cmux.notifications.deviceTokenHex")

        let heldMutation = Task {
            await service.unregisterFromServer()
        }
        await started.waitUntilStarted()
        await provider.clearSession()

        let queuedSignOut = Task {
            await service.unregisterFromServer(
                accountID: "account-a",
                accessToken: "captured-access",
                refreshToken: "captured-refresh"
            )
        }
        queuedSignOut.cancel()
        // Cancellation must remove the waiter while the first mutation still
        // owns the intent gate. If it were allowed to wait for the gate, this
        // await would deadlock until the blocker below is released.
        await queuedSignOut.value

        await blocker.release()
        await heldMutation.value

        let queueText = defaults.data(
            forKey: "cmux.notifications.pendingUnregisters.v2"
        ).flatMap { String(data: $0, encoding: .utf8) }
        #expect(queueText?.contains("account-a") == true)
        #expect(await PushRegistrationURLProtocol.script.requests.isEmpty)
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
        let queueText = defaults.data(
            forKey: "cmux.notifications.pendingUnregisters.v2"
        ).flatMap { String(data: $0, encoding: .utf8) }
        #expect(queueText?.contains("account-a") == true)
        #expect(queueText?.contains("account-b") == false)
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
        let queueText = defaults.data(
            forKey: "cmux.notifications.pendingUnregisters.v2"
        ).flatMap { String(data: $0, encoding: .utf8) }
        #expect(queueText?.contains("account-a") == true)
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

    @Test func disabledStartupDurablyRecoversOwnedRegistrationCleanup() async {
        await PushRegistrationURLProtocol.script.reset([.response(200)])
        let suite = "push-disabled-startup-\(UUID().uuidString)"
        let (service, defaults) = makeScriptedService(
            suite: suite,
            accountID: "account-a",
            seedDefaults: { defaults in
                defaults.set(false, forKey: "cmux.notifications.pushEnabled")
                defaults.set("aa", forKey: "cmux.notifications.deviceTokenHex")
                defaults.set(
                    "account-a",
                    forKey: "cmux.notifications.registeredAccountID"
                )
            }
        )

        let persisted = try? JSONDecoder().decode(
            [[String: String]].self,
            from: defaults.data(
                forKey: "cmux.notifications.pendingUnregisters.v2"
            ) ?? Data()
        )
        #expect(persisted == [["tokenHex": "aa", "accountID": "account-a"]])

        await service.syncTokenIfPossible()

        #expect(
            await PushRegistrationURLProtocol.script.requests
                .map(\.httpMethod) == ["DELETE"]
        )
        #expect(
            defaults.data(forKey: "cmux.notifications.pendingUnregisters.v2")
                == nil
        )
    }

    @Test func absentPreferenceDoesNotScheduleRegistrationCleanup() async {
        await PushRegistrationURLProtocol.script.reset([.response(200)])
        let suite = "push-absent-preference-startup-\(UUID().uuidString)"
        let (service, defaults) = makeScriptedService(
            suite: suite,
            accountID: "account-a",
            seedDefaults: { defaults in
                defaults.removeObject(forKey: "cmux.notifications.pushEnabled")
                defaults.set("aa", forKey: "cmux.notifications.deviceTokenHex")
                defaults.set(
                    "account-a",
                    forKey: "cmux.notifications.registeredAccountID"
                )
            }
        )

        #expect(
            defaults.object(forKey: "cmux.notifications.pushEnabled") == nil
        )
        #expect(
            defaults.data(forKey: "cmux.notifications.pendingUnregisters.v2")
                == nil
        )

        await service.syncTokenIfPossible()
        #expect(await PushRegistrationURLProtocol.script.requests.isEmpty)
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

        let persisted = try? JSONDecoder().decode(
            [[String: String]].self,
            from: defaults.data(
                forKey: "cmux.notifications.pendingUnregisters.v2"
            ) ?? Data()
        )
        #expect(persisted == [["tokenHex": "ab", "accountID": "account-a"]])
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
        let queueText = defaults.data(
            forKey: "cmux.notifications.pendingUnregisters.v2"
        ).flatMap { String(data: $0, encoding: .utf8) }
        #expect(queueText?.contains("account-a") == true)
        #expect(queueText?.contains("account-b") == false)
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

        #expect(
            defaults.data(forKey: "cmux.notifications.pendingUnregisters.v2")
                != nil
        )
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
        let disable = Task {
            await service.setEnabled(false)
        }
        await blocker.release()
        await upload.value
        await disable.value

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

    @Test func inFlightRegistrationPersistsCleanupOwnerBeforePostCompletes() async {
        let started = TestPhaseSignal()
        let blocker = TestContinuationBlocker()
        await PushRegistrationURLProtocol.script.reset([
            .gatedResponse(200, started: started, blocker: blocker),
            .response(200),
        ])
        let (service, defaults) = makeScriptedService(accountID: "account-a")
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")

        let upload = Task {
            await service.register(deviceToken: Data([0xAA]))
        }
        await started.waitUntilStarted()

        let queueText = defaults.data(
            forKey: "cmux.notifications.pendingUnregisters.v2"
        ).flatMap { String(data: $0, encoding: .utf8) }
        #expect(queueText?.contains("account-a") == true)

        await blocker.release()
        await upload.value
        #expect(
            defaults.data(forKey: "cmux.notifications.pendingUnregisters.v2")
                == nil
        )
    }

    @Test func disablingDuringInFlightEnableSerializesBackendMutation() async {
        let started = TestPhaseSignal()
        let blocker = TestContinuationBlocker()
        await PushRegistrationURLProtocol.script.reset([
            .gatedResponse(200, started: started, blocker: blocker),
            .response(200),
        ])
        let (service, defaults) = makeScriptedService(accountID: "account-a")
        defaults.set("aa", forKey: "cmux.notifications.deviceTokenHex")

        let enable = Task { await service.setEnabled(true) }
        await started.waitUntilStarted()
        let disable = Task { await service.setEnabled(false) }

        await blocker.release()
        await enable.value
        await disable.value

        #expect(
            await PushRegistrationURLProtocol.script.requests
                .map(\.httpMethod) == ["POST", "DELETE"]
        )
        #expect(defaults.bool(forKey: "cmux.notifications.pushEnabled") == false)
    }

    @Test func disablePersistsOptOutBeforeServerCleanupCompletes() async {
        let started = TestPhaseSignal()
        let blocker = TestContinuationBlocker()
        await PushRegistrationURLProtocol.script.reset([
            .gatedResponse(200, started: started, blocker: blocker),
        ])
        let (service, defaults) = makeScriptedService(accountID: "account-a")
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")
        defaults.set("aa", forKey: "cmux.notifications.deviceTokenHex")
        defaults.set(
            "account-a",
            forKey: "cmux.notifications.registeredAccountID"
        )

        let disable = Task {
            await service.disableAndUnregister()
        }
        await started.waitUntilStarted()

        #expect(defaults.bool(forKey: "cmux.notifications.pushEnabled") == false)

        await blocker.release()
        await disable.value
    }

    @Test func supersededQueuedOptOutCannotUndoAReenable() async {
        let started = TestPhaseSignal()
        let blocker = TestContinuationBlocker()
        await PushRegistrationURLProtocol.script.reset([
            .gatedResponse(200, started: started, blocker: blocker),
            .response(200),
        ])
        let (service, defaults) = makeScriptedService(accountID: "account-a")
        defaults.set("aa", forKey: "cmux.notifications.deviceTokenHex")

        let firstEnable = Task {
            await service.applyEnabledIntent(true, generation: 1)
        }
        await started.waitUntilStarted()
        let optOut = Task {
            await service.applyEnabledIntent(false, generation: 2)
        }
        let reenable = Task {
            await service.applyEnabledIntent(true, generation: 3)
        }

        await blocker.release()
        await firstEnable.value
        await optOut.value
        await reenable.value

        #expect(defaults.bool(forKey: "cmux.notifications.pushEnabled"))
        #expect(await service.snapshot.backendState == .registered)
        #expect(
            await PushRegistrationURLProtocol.script.requests
                .map(\.httpMethod) == ["POST", "POST"]
        )
    }

    @Test func coordinatorGenerationZeroEnablesPreviouslyAuthorizedStartup() async {
        await PushRegistrationURLProtocol.script.reset([.response(200)])
        let (service, defaults) = makeScriptedService(accountID: "account-a")
        defaults.set("aa", forKey: "cmux.notifications.deviceTokenHex")

        await service.applyEnabledIntent(true, generation: 0)

        #expect(defaults.bool(forKey: "cmux.notifications.pushEnabled"))
        #expect(await service.snapshot.backendState == .registered)
        #expect(
            await PushRegistrationURLProtocol.script.requests
                .map(\.httpMethod) == ["POST"]
        )
    }

    @Test func directMutationSupersedesQueuedCoordinatorIntent() async {
        let started = TestPhaseSignal()
        let blocker = TestContinuationBlocker()
        await PushRegistrationURLProtocol.script.reset([
            .gatedResponse(200, started: started, blocker: blocker),
            .response(200),
        ])
        let (service, defaults) = makeScriptedService(accountID: "account-a")
        defaults.set("aa", forKey: "cmux.notifications.deviceTokenHex")

        let firstEnable = Task {
            await service.applyEnabledIntent(true, generation: 1)
        }
        await started.waitUntilStarted()
        let queuedOptOut = Task {
            await service.applyEnabledIntent(false, generation: 2)
        }
        let directReenable = Task {
            await service.setEnabled(true)
        }

        await blocker.release()
        await firstEnable.value
        await queuedOptOut.value
        await directReenable.value

        #expect(defaults.bool(forKey: "cmux.notifications.pushEnabled"))
        #expect(await service.snapshot.backendState == .registered)
        #expect(
            await PushRegistrationURLProtocol.script.requests
                .map(\.httpMethod) == ["POST", "POST"]
        )
    }

    @Test func cancelledQueuedRegistrationLeavesRecoverableState() async {
        let started = TestPhaseSignal()
        let blocker = TestContinuationBlocker()
        await PushRegistrationURLProtocol.script.reset([
            .gatedResponse(200, started: started, blocker: blocker),
            .response(200),
            .response(200),
        ])
        let (service, defaults) = makeScriptedService(
            retryDelays: [],
            accountID: "account-a"
        )
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")

        let first = Task {
            await service.register(deviceToken: Data([0xAA]))
        }
        await started.waitUntilStarted()

        let queued = Task {
            await service.register(deviceToken: Data([0xAA]))
        }
        queued.cancel()

        await blocker.release()
        await first.value
        await queued.value

        #expect(
            await service.snapshot.backendState
                != PushRegistrationBackendState.registering
        )
    }

    @Test func concurrentSameGenerationSharesRegistrationMutation() async {
        let started = TestPhaseSignal()
        let blocker = TestContinuationBlocker()
        await PushRegistrationURLProtocol.script.reset([
            .gatedResponse(200, started: started, blocker: blocker),
        ])
        let (service, defaults) = makeScriptedService(accountID: "account-a")
        defaults.set("aa", forKey: "cmux.notifications.deviceTokenHex")

        let firstEnable = Task {
            await service.applyEnabledIntent(true, generation: 1)
        }
        await started.waitUntilStarted()
        let secondEnable = Task {
            await service.applyEnabledIntent(true, generation: 1)
        }

        await blocker.release()
        await firstEnable.value
        await secondEnable.value
        await service.applyEnabledIntent(true, generation: 1)

        #expect(
            await PushRegistrationURLProtocol.script.requests
                .map(\.httpMethod) == ["POST"]
        )
        #expect(await service.snapshot.backendState == .registered)
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
        let unregister = Task {
            await service.unregisterFromServer(
                accountID: "account-a",
                accessToken: "a-captured-access",
                refreshToken: "a-captured-refresh"
            )
        }
        await blocker.release()
        await upload.value
        await unregister.value

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
        let newUpload = Task {
            await service.syncTokenIfPossible()
        }
        await blocker.release()
        await oldUpload.value
        await newUpload.value

        let requests = await PushRegistrationURLProtocol.script.requests
        #expect(
            requests.map(\.httpMethod)
                == ["POST", "POST", "DELETE", "POST"]
        )
        #expect(
            requests.map {
                $0.value(forHTTPHeaderField: "Authorization")
            } == [
                "Bearer a-access",
                "Bearer b-access",
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
        let pendingText = defaults.data(
            forKey: "cmux.notifications.pendingUnregisters.v2"
        ).flatMap { String(data: $0, encoding: .utf8) }
        #expect(pendingText?.contains("aa") == true)

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

    @Test func successfulReassignmentClearsOldTombstoneWithoutLosingNewOwner() async {
        await PushRegistrationURLProtocol.script.reset([.response(200)])
        let suite = "push-owner-reassignment-\(UUID().uuidString)"
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
            }
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
