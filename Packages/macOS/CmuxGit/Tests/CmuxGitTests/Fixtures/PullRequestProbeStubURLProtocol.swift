import Foundation

/// Isolated URLProtocol storage for pull-request probe-service tests.
///
/// The request-coordinator suite runs concurrently and owns a separate stub;
/// sharing one static queue lets either suite consume the other's responses.
final class PullRequestProbeStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [GitHubPullRequestStub] = []
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func reset(stubs: [GitHubPullRequestStub]) {
        lock.lock()
        self.stubs = stubs
        requests = []
        lock.unlock()
    }

    static func capturedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.github.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        guard !Self.stubs.isEmpty else {
            Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let stub = Self.stubs.removeFirst()
        Self.requests.append(request)
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: nil,
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
