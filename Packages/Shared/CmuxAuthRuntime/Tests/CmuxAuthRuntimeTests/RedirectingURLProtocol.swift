import Foundation

/// Simulates a canonicalizing redirect that downgrades the request method to GET
/// and drops the body — Foundation's documented 301/302/303 behavior — then
/// records what actually arrives at the redirect target. Host families drive the
/// behaviors the delegate must have:
///   - `same-origin-start.test` 301s to a distinct path on the SAME host, so the
///     delegate restores method+body (the realistic recurrence).
///   - `xorigin-start.test` 301s to a DIFFERENT host, so the delegate must
///     refuse the redirect entirely (the target is never reached).
///   - `see-other-start.test` 303s to a distinct path on the SAME host, which
///     the delegate must leave as Foundation's GET (303 = GET follow-up by spec).
/// A distinct canonical path (not a trailing-slash variant, whose slash URL
/// normalization can strip and re-match the origin path into a redirect loop) is
/// used. The arriving method + body are recorded in ``recorder``.
final class RedirectingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static let recorder = RedirectTargetRecorder()
    static let originPath = "/api/device-tokens"
    static let canonicalPath = "/api/device-tokens-canonical"
    static let sameOriginHost = "same-origin-start.test"
    static let crossOriginStartHost = "xorigin-start.test"
    static let crossOriginEndHost = "xorigin-end.test"
    static let seeOtherHost = "see-other-start.test"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if host == Self.sameOriginHost, url.path == Self.originPath {
            redirect(from: url, to: sameHostCanonical(of: url), status: 301)
            return
        }
        if host == Self.seeOtherHost, url.path == Self.originPath {
            redirect(from: url, to: sameHostCanonical(of: url), status: 303)
            return
        }
        if host == Self.crossOriginStartHost {
            redirect(from: url, to: URL(string: "https://\(Self.crossOriginEndHost)\(Self.canonicalPath)")!, status: 301)
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

    /// The canonical path on the SAME host as `url` (same scheme/host/port).
    private func sameHostCanonical(of url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.path = Self.canonicalPath
        return components.url!
    }

    /// Emit a redirect whose proposed request is a body-less GET (Foundation's
    /// 301/302/303 behavior); the redirect delegate, when installed, decides
    /// whether to restore, refuse, or follow it.
    private func redirect(from url: URL, to target: URL, status: Int) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": target.absoluteString]
        )!
        var proposed = URLRequest(url: target)
        proposed.httpMethod = "GET"
        client?.urlProtocol(self, wasRedirectedTo: proposed, redirectResponse: response)
        // Finish the original load so a REFUSED redirect (delegate returns nil)
        // completes the task promptly with this 3xx instead of hanging until the
        // request timeout. A FOLLOWED redirect starts a fresh task and ignores
        // this completion.
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
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
