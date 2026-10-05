import Foundation
import Testing

@testable import CmuxBrowser

/// CFNetwork can move a request to another URL without a redirect the
/// delegate sees (an HSTS upgrade from `http` to `https`). The fetcher must
/// judge the URL the response came from, not only the URLs it asked for.
@Suite("Browser REPL fetch effective URL", .serialized)
struct BrowserReplFetchEffectiveURLTests {
    /// Answers every request as if it had been upgraded to `https`, with a
    /// cookie and a body, and no redirect.
    final class UpgradingProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "upgrade.test"
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
            parts.scheme = "https"
            let upgraded = parts.url ?? url
            let response = HTTPURLResponse(
                url: upgraded,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/plain", "Set-Cookie": "sid=upgraded; Path=/"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("prohibited-endpoint-body".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    /// Records the driver methods the fetcher calls.
    final class RecordingDriver: BrowserReplDriver, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        var methods: [String] { lock.withLock { calls } }
        var capabilities: [String] { [] }

        func call(method: String, paramsJSON: String) async -> Result<String, BrowserReplDriverError> {
            lock.withLock { calls.append(method) }
            return .success(method == "cookies.get" ? "[]" : "null")
        }

        func attach(eventSink: @escaping BrowserReplDriverEventSink) {}
        func detach() {}
    }

    @Test("A response from a URL the policy blocks fails, and its cookies are not stored")
    func upgradedResponseIsJudged() async throws {
        let driver = RecordingDriver()
        let fetcher = BrowserReplFetcher(driver: driver, protocolClasses: [UpgradingProtocol.self])
        defer { fetcher.invalidate() }
        let policy = try {
            var policy = BrowserReplDomainPolicy()
            policy.prohibited = [try BrowserReplDomainPattern.parse("https://upgrade.test", title: "t")]
            policy.locked = true
            return policy
        }()
        fetcher.setBlockReason { policy.blockReason($0) }
        #expect(policy.blockReason("http://upgrade.test/x") == nil)

        let request: [String: Any] = ["url": "http://upgrade.test/x", "method": "GET"]
        let result = await fetcher.fetch(requestJSON: JSONSerialization.browserReplString(request) ?? "{}")
        switch result {
        case .success(let json):
            Issue.record("the response from the prohibited URL was returned: \(json)")
        case .failure(let error):
            #expect(error.code == "blocked", "\(error)")
            #expect(error.message.contains("https://upgrade.test/x"), "\(error.message)")
        }
        #expect(!driver.methods.contains("cookies.set"), "\(driver.methods)")
    }
}
