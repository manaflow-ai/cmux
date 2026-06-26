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

/// Lock-guarded record of the HTTP method that reached a redirect's TARGET, so
/// the test can read it synchronously right after the awaited upload completes
/// (the protocol records before it finishes loading the response).
final class RedirectTargetRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _targetMethod: String?
    func record(targetMethod: String?) {
        lock.lock(); defer { lock.unlock() }
        _targetMethod = targetMethod
    }
    func targetMethod() -> String? {
        lock.lock(); defer { lock.unlock() }
        return _targetMethod
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        _targetMethod = nil
    }
}

/// Simulates a canonicalizing 301 (e.g. the historical `cmux.dev` -> `cmux.com`)
/// that downgrades the request method to GET — Foundation's documented 301/302
/// behavior — then records the method that actually arrives at the redirect
/// target. The first hop (host `redirect-origin.test`) answers 301 by proposing
/// a body-less GET to the canonical host; the second hop records what it saw.
final class RedirectingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static let recorder = RedirectTargetRecorder()
    static let canonicalURL = URL(string: "https://redirect-canonical.test/api/device-tokens")!

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if url.host == "redirect-origin.test" {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 301,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": Self.canonicalURL.absoluteString]
            )!
            // Foundation proposes a body-less GET on a 301/302; the redirect
            // delegate (once installed) is what restores the original method.
            var proposed = URLRequest(url: Self.canonicalURL)
            proposed.httpMethod = "GET"
            client?.urlProtocol(self, wasRedirectedTo: proposed, redirectResponse: response)
            return
        }
        Self.recorder.record(targetMethod: request.httpMethod)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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
        // redirect. When the API base URL canonicalizes (the historical
        // cmux.dev -> cmux.com 301 that "killed beta/prod push"), the upload
        // arrived as a GET with no body, which `/api/device-tokens` has no
        // handler for, so the device token silently never registered and iOS
        // push went dead end-to-end. The registration request must survive the
        // redirect as a POST.
        RedirectingURLProtocol.recorder.reset()
        let suite = "push-redirect-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingURLProtocol.self]
        let service = PushRegistrationService(
            tokenProvider: FakeTokenProvider(),
            apiBaseURL: "https://redirect-origin.test",
            bundleID: "dev.cmux.app.beta",
            apnsEnvironment: "production",
            suiteName: suite,
            session: URLSession(configuration: configuration)
        )

        await service.register(deviceToken: Data([0xAB, 0xCD]))
        // Enabling uploads the cached token via POST /api/device-tokens, which
        // the stub 301-redirects to the canonical host.
        await service.setEnabled(true)

        #expect(RedirectingURLProtocol.recorder.targetMethod() == "POST")
    }
}
