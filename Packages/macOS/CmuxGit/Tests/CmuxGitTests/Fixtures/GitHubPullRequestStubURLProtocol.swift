import Foundation

// URLProtocol callbacks are synchronous, so the lock protects the fixture's small shared snapshot.
final class GitHubPullRequestStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [GitHubPullRequestStub] = []
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var activeRequestCount = 0
    nonisolated(unsafe) private static var maximumActiveRequestCount = 0
    nonisolated(unsafe) private static var gatedFinishes: [String: @Sendable () -> Void] = [:]
    nonisolated(unsafe) private static var requestSignal = GitHubPullRequestTestSignal()

    @discardableResult
    static func reset(stubs: [GitHubPullRequestStub]) -> GitHubPullRequestTestSignal {
        lock.lock()
        self.stubs = stubs
        requests = []
        activeRequestCount = 0
        maximumActiveRequestCount = 0
        gatedFinishes = [:]
        let signal = GitHubPullRequestTestSignal()
        requestSignal = signal
        lock.unlock()
        return signal
    }

    static func capturedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func maximumConcurrentRequestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActiveRequestCount
    }

    static func releaseGate(_ gate: String) {
        lock.lock()
        let finish = gatedFinishes.removeValue(forKey: gate)
        lock.unlock()
        finish?()
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
        Self.activeRequestCount += 1
        Self.maximumActiveRequestCount = max(Self.maximumActiveRequestCount, Self.activeRequestCount)
        Self.lock.unlock()

        let finish: @Sendable () -> Void = { [self] in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.statusCode,
                httpVersion: nil,
                headerFields: stub.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
            Self.lock.lock()
            Self.activeRequestCount -= 1
            Self.lock.unlock()
        }
        Self.lock.lock()
        if let gate = stub.gate { Self.gatedFinishes[gate] = finish }
        Self.requests.append(request)
        let requestCount = Self.requests.count
        let signal = Self.requestSignal
        Self.lock.unlock()
        Task { await signal.signal(requestCount) }
        if stub.gate != nil {
            return
        } else {
            finish()
        }
    }

    override func stopLoading() {}
}
