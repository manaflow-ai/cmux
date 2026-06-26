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

    @Test func deviceTokenRegistrationSurvivesARedirectAsPOST() async {
        // Regression for https://github.com/manaflow-ai/cmux/issues/6270.
        // Foundation downgrades POST/DELETE to a body-less GET on a 301/302
        // redirect. When the API base URL canonicalizes (e.g. a trailing-slash
        // normalization), the upload arrived as a GET with no body, which
        // `/api/device-tokens` has no handler for, so the device token silently
        // never registered and iOS push went dead end-to-end. The registration
        // request must survive a same-origin redirect as a POST *with its body*
        // (a verb-only fix that dropped the body would still break the route).
        RedirectingURLProtocol.recorder.reset()
        let suite = "push-redirect-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingURLProtocol.self]
        let service = PushRegistrationService(
            tokenProvider: FakeTokenProvider(),
            apiBaseURL: "https://\(RedirectingURLProtocol.sameOriginHost)",
            bundleID: "dev.cmux.app.beta",
            apnsEnvironment: "production",
            suiteName: suite,
            session: URLSession(configuration: configuration)
        )

        await service.register(deviceToken: Data([0xAB, 0xCD]))
        // Enabling uploads the cached token via POST /api/device-tokens, which
        // the stub 301-redirects (same origin) to the canonical path.
        await service.setEnabled(true)

        #expect(RedirectingURLProtocol.recorder.targetMethod() == "POST")
        // The JSON body (deviceToken/bundleId/environment/platform) must survive
        // too, not just the verb.
        #expect((RedirectingURLProtocol.recorder.targetBodyByteCount() ?? 0) > 0)
    }

    @Test func deviceTokenRegistrationFailsClosedAcrossOrigins() async {
        // Security: a cross-origin redirect must be REFUSED, not followed.
        // Foundation forwards custom headers (X-Stack-Refresh-Token, ...) to the
        // new origin even though it strips Authorization, so the delegate cancels
        // the redirect outright — nothing (body or headers) reaches the other
        // origin, and the cross-origin target is never contacted.
        RedirectingURLProtocol.recorder.reset()
        let suite = "push-xorigin-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingURLProtocol.self]
        let service = PushRegistrationService(
            tokenProvider: FakeTokenProvider(),
            apiBaseURL: "https://\(RedirectingURLProtocol.crossOriginStartHost)",
            bundleID: "dev.cmux.app.beta",
            apnsEnvironment: "production",
            suiteName: suite,
            session: URLSession(configuration: configuration)
        )

        await service.register(deviceToken: Data([0xAB, 0xCD]))
        await service.setEnabled(true)

        // The redirect was refused, so the cross-origin target is never reached.
        #expect(RedirectingURLProtocol.recorder.targetMethod() == nil)
    }

    @Test func deviceTokenRegistrationRefusesCrossOrigin308() async {
        // A method-preserving 307/308 cross-origin redirect must ALSO be refused —
        // it keeps the POST and would forward the payload + custom credential
        // headers to the other origin. Origin is checked before the method, so a
        // 308 cannot slip past; the target is never reached.
        RedirectingURLProtocol.recorder.reset()
        let suite = "push-xorigin308-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingURLProtocol.self]
        let service = PushRegistrationService(
            tokenProvider: FakeTokenProvider(),
            apiBaseURL: "https://\(RedirectingURLProtocol.crossOrigin308StartHost)",
            bundleID: "dev.cmux.app.beta",
            apnsEnvironment: "production",
            suiteName: suite,
            session: URLSession(configuration: configuration)
        )

        await service.register(deviceToken: Data([0xAB, 0xCD]))
        await service.setEnabled(true)

        #expect(RedirectingURLProtocol.recorder.targetMethod() == nil)
    }

    @Test func deviceTokenRegistrationLeavesSeeOtherAsGET() async {
        // A 303 ("See Other") is by spec a GET follow-up to a different resource,
        // so the delegate must NOT replay the POST body onto it (that would be a
        // second mutating call). It is left as Foundation's body-less GET.
        RedirectingURLProtocol.recorder.reset()
        let suite = "push-seeother-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingURLProtocol.self]
        let service = PushRegistrationService(
            tokenProvider: FakeTokenProvider(),
            apiBaseURL: "https://\(RedirectingURLProtocol.seeOtherHost)",
            bundleID: "dev.cmux.app.beta",
            apnsEnvironment: "production",
            suiteName: suite,
            session: URLSession(configuration: configuration)
        )

        await service.register(deviceToken: Data([0xAB, 0xCD]))
        await service.setEnabled(true)

        #expect(RedirectingURLProtocol.recorder.targetMethod() == "GET")
        #expect((RedirectingURLProtocol.recorder.targetBodyByteCount() ?? 0) == 0)
    }
}
