import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Records every URLRequest the push service performs, returning 200.
final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    // Mutations are serialized by the URL loading system; a lock-free actor
    // box keeps captured requests for assertions.
    nonisolated(unsafe) static let recorder = RequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Task { await RecordingURLProtocol.recorder.record(request) }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

actor RequestRecorder {
    private(set) var methods: [String] = []
    private(set) var requests: [URLRequest] = []
    func record(_ request: URLRequest) {
        methods.append(request.httpMethod ?? "?")
        requests.append(request)
    }
    func reset() {
        methods = []
        requests = []
    }
}

struct FakeTokenProvider: TokenProviding {
    var access: String? = "access"
    var refresh: String? = "refresh"
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
        retryDelays: [Duration] = []
    ) -> (PushRegistrationService, UserDefaults) {
        let suite = "push-scripted-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PushRegistrationURLProtocol.self]
        let service = PushRegistrationService(
            tokenProvider: tokenProvider,
            apiBaseURL: "https://example.test",
            bundleID: "dev.cmux.ios.push1",
            apnsEnvironment: "sandbox",
            suiteName: suite,
            session: URLSession(configuration: configuration),
            retryDelays: retryDelays,
            retryJitter: { _ in 1 }
        )
        return (service, defaults)
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

        for _ in 0..<100 where await service.snapshot.backendState != .registered {
            await Task.yield()
        }
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

        for _ in 0..<100 where await service.snapshot.backendState != .registered {
            await Task.yield()
        }
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

    @Test func sameOrigin301PreservesRegistrationMethodBodyAndCredentials() async throws {
        await PushRedirectURLProtocol.state.reset(.sameOrigin301)
        let suite = "push-redirect-\(UUID().uuidString)"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PushRedirectURLProtocol.self]
        let service = PushRegistrationService(
            tokenProvider: FakeTokenProvider(),
            apiBaseURL: "https://\(PushRedirectURLProtocol.startHost)",
            bundleID: "dev.cmux.ios.push1",
            apnsEnvironment: "sandbox",
            suiteName: suite,
            session: URLSession(configuration: configuration)
        )

        await service.register(deviceToken: Data(repeating: 0xAB, count: 32))
        await service.setEnabled(true)

        let target = try #require(await PushRedirectURLProtocol.state.targetRequests.first)
        #expect(target.httpMethod == "POST")
        #expect(target.httpBody != nil || target.httpBodyStream != nil)
        #expect(target.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        #expect(target.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == "refresh")
    }

    @Test func crossOrigin308FailsClosedBeforeSendingTokenOrCustomCredentials() async {
        await PushRedirectURLProtocol.state.reset(.crossOrigin308)
        let suite = "push-cross-origin-\(UUID().uuidString)"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PushRedirectURLProtocol.self]
        let service = PushRegistrationService(
            tokenProvider: FakeTokenProvider(),
            apiBaseURL: "https://\(PushRedirectURLProtocol.startHost)",
            bundleID: "dev.cmux.ios.push1",
            apnsEnvironment: "sandbox",
            suiteName: suite,
            session: URLSession(configuration: configuration)
        )

        await service.register(deviceToken: Data(repeating: 0xAB, count: 32))
        await service.setEnabled(true)

        #expect(await PushRedirectURLProtocol.state.targetRequests.isEmpty)
    }
}
