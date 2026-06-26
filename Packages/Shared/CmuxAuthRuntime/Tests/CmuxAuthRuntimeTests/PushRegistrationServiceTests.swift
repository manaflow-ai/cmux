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

/// Lock-guarded record of the HTTP method AND body byte count that reached a
/// redirect's TARGET, so the test can read them synchronously right after the
/// awaited upload completes (the protocol records before it finishes loading the
/// response).
final class RedirectTargetRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _targetMethod: String?
    private var _targetBodyByteCount: Int?
    func record(targetMethod: String?, bodyByteCount: Int?) {
        lock.lock(); defer { lock.unlock() }
        _targetMethod = targetMethod
        _targetBodyByteCount = bodyByteCount
    }
    func targetMethod() -> String? {
        lock.lock(); defer { lock.unlock() }
        return _targetMethod
    }
    func targetBodyByteCount() -> Int? {
        lock.lock(); defer { lock.unlock() }
        return _targetBodyByteCount
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        _targetMethod = nil
        _targetBodyByteCount = nil
    }
}

/// Simulates a canonicalizing 301 that downgrades the request method to GET and
/// drops the body — Foundation's documented 301/302 behavior — then records what
/// actually arrives at the redirect target. Two host families drive the two
/// behaviors the delegate must have:
///   - `same-origin-start.test` 301s to a distinct path on the SAME host, so the
///     delegate restores method+body (the realistic recurrence).
///   - `xorigin-start.test` 301s to a DIFFERENT host, so the delegate must fail
///     closed and leave Foundation's proposed body-less GET (no payload leak).
/// A distinct canonical path (not a trailing-slash variant, whose slash URL
/// normalization can strip and re-match the origin path into a redirect loop) is
/// used for both.
final class RedirectingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static let recorder = RedirectTargetRecorder()
    static let originPath = "/api/device-tokens"
    static let canonicalPath = "/api/device-tokens-canonical"
    static let sameOriginHost = "same-origin-start.test"
    static let crossOriginStartHost = "xorigin-start.test"
    static let crossOriginEndHost = "xorigin-end.test"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if host == Self.sameOriginHost, url.path == Self.originPath {
            var canonical = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            canonical.path = Self.canonicalPath
            redirect(from: url, to: canonical.url!)
            return
        }
        if host == Self.crossOriginStartHost {
            redirect(from: url, to: URL(string: "https://\(Self.crossOriginEndHost)\(Self.canonicalPath)")!)
            return
        }
        // The redirect target (same host canonical path, or the cross-origin
        // end host): record what arrived and complete.
        Self.recorder.record(targetMethod: request.httpMethod, bodyByteCount: Self.bodyByteCount(of: request))
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// Emit a 301 whose proposed request is a body-less GET (Foundation's 301/302
    /// behavior); the redirect delegate, when installed, is what restores it.
    private func redirect(from url: URL, to target: URL) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: 301,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": target.absoluteString]
        )!
        var proposed = URLRequest(url: target)
        proposed.httpMethod = "GET"
        client?.urlProtocol(self, wasRedirectedTo: proposed, redirectResponse: response)
    }

    /// Body length from `httpBody`, or by draining `httpBodyStream` (URLSession
    /// may have moved the body into a stream by the time it reaches the protocol).
    private static func bodyByteCount(of request: URLRequest) -> Int {
        if let body = request.httpBody { return body.count }
        guard let stream = request.httpBodyStream else { return 0 }
        stream.open()
        defer { stream.close() }
        var total = 0
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            total += read
        }
        return total
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
        // Security: a cross-origin redirect must NOT replay the method+body to
        // the new host. Foundation strips Authorization off-origin, so restoring
        // the body there would resend the (potentially sensitive) payload
        // unauthenticated to wherever the redirect points. The delegate leaves
        // Foundation's proposed body-less GET, so it fails loudly instead.
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

        // The cross-origin target sees Foundation's downgraded GET with no body,
        // never a restored POST carrying the payload.
        #expect(RedirectingURLProtocol.recorder.targetMethod() == "GET")
        #expect((RedirectingURLProtocol.recorder.targetBodyByteCount() ?? 0) == 0)
    }
}
