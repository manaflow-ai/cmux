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

    /// The Cookie header each request reached the network with, by URL.
    final class CookieRecordingProtocol: URLProtocol {
        nonisolated(unsafe) private static var recorded: [(url: String, cookie: String?)] = []
        private static let lock = NSLock()

        static func reset() { lock.withLock { recorded = [] } }
        static var requests: [(url: String, cookie: String?)] { lock.withLock { recorded } }

        override class func canInit(with request: URLRequest) -> Bool {
            ["upgrade.test", "hop.test"].contains(request.url?.host ?? "")
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else { return }
            Self.lock.withLock { Self.recorded.append((url.absoluteString, request.value(forHTTPHeaderField: "Cookie"))) }
            if url.host == "hop.test" {
                let next = URLRequest(url: URL(string: "http://upgrade.test/landing")!)
                let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "http://upgrade.test/landing"])!
                client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("ok".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    /// Gives every URL the tab cookie `sid=tab-secret`.
    final class CookieDriver: BrowserReplDriver, @unchecked Sendable {
        var capabilities: [String] { [] }

        func call(method: String, paramsJSON: String) async -> Result<String, BrowserReplDriverError> {
            .success(method == "cookies.get" ? #"[{"name":"sid","value":"tab-secret"}]"# : "null")
        }

        func attach(eventSink: @escaping BrowserReplDriverEventSink) {}
        func detach() {}
    }

    private func fetched(
        allowing allowed: [String],
        fetching url: String,
        method: String = "GET",
        headers: [[String]] = [],
        body: String? = nil
    ) async throws -> (sent: [(url: String, cookie: String?)], result: Result<String, BrowserReplDriverError>) {
        CookieRecordingProtocol.reset()
        let fetcher = BrowserReplFetcher(driver: CookieDriver(), protocolClasses: [CookieRecordingProtocol.self])
        defer { fetcher.invalidate() }
        var policy = BrowserReplDomainPolicy()
        policy.allowed = try allowed.map { try BrowserReplDomainPattern.parse($0, title: "t") }
        policy.locked = true
        fetcher.setBlockReason { [policy] in policy.blockReason($0) }
        var request: [String: Any] = ["url": url, "method": method, "headers": headers]
        if let body { request["bodyBase64"] = Data(body.utf8).base64EncodedString() }
        let result = await fetcher.fetch(requestJSON: JSONSerialization.browserReplString(request) ?? "{}")
        return (CookieRecordingProtocol.requests, result)
    }

    private func cookies(allowing allowed: [String], fetching url: String) async throws -> [(url: String, cookie: String?)] {
        try await fetched(allowing: allowed, fetching: url).sent
    }

    /// r25 native#1, reversed by r26 native#2 (lane e5): CFNetwork upgrades
    /// an `http` request to a host it has an HSTS entry for (one it saw, or
    /// the preloaded list) to `https` before the request is sent, with its
    /// method, headers and body, and tells the delegate nothing until the
    /// response. Stripping cookies left the body and caller headers going
    /// to the blocked `https` origin, so an `http` URL whose `https` form
    /// the policy blocks is refused before anything is sent.
    @Test("An http URL whose https form the policy blocks is refused before anything is sent")
    func httpOnlyPolicyIsRefused() async throws {
        let (sent, result) = try await fetched(
            allowing: ["http://upgrade.test"],
            fetching: "http://upgrade.test/x",
            method: "POST",
            headers: [["Authorization", "Bearer caller-token"], ["X-Custom", "caller-value"]],
            body: "request-body-secret"
        )
        #expect(sent.isEmpty, "the request reached the network: \(sent)")
        guard case .failure(let error) = result else {
            Issue.record("the fetch succeeded: \(result)")
            return
        }
        #expect(error.code == "blocked", "\(error)")
        #expect(error.message.contains("https://upgrade.test/x"), "\(error.message)")
        #expect(error.message.contains("allow"), "the refusal does not say to allow the https form: \(error.message)")
    }

    @Test("A redirect hop to an http URL whose https form the policy blocks fails the fetch")
    func redirectToHTTPOnlyIsRefused() async throws {
        let (sent, result) = try await fetched(allowing: ["https://hop.test", "http://upgrade.test"], fetching: "https://hop.test/start")
        #expect(sent.map(\.url) == ["https://hop.test/start"], "the hop reached the network: \(sent)")
        guard case .failure(let error) = result else {
            Issue.record("the fetch succeeded: \(result)")
            return
        }
        #expect(error.code == "blocked", "\(error)")
        #expect(error.message.contains("https://upgrade.test/landing"), "\(error.message)")
    }

    /// HSTS never applies to an IP address, and a loopback request stays on
    /// the machine, so those `http` URLs are requested as before.
    @Test("An IP address or loopback host has no HSTS form to refuse")
    func ipAndLoopbackAreNotUpgraded() {
        for url in ["http://127.0.0.1/x", "http://[::1]:8080/x", "http://192.0.2.1/x", "http://localhost/x"] {
            #expect(BrowserReplFetcher.hstsUpgraded(URL(string: url)!) == nil, "\(url)")
        }
        #expect(BrowserReplFetcher.hstsUpgraded(URL(string: "http://upgrade.test:80/x")!)?.absoluteString == "https://upgrade.test/x")
    }

    @Test("An http URL the policy allows on https too keeps its cookies")
    func bothSchemesKeepCookies() async throws {
        for allowed in [["upgrade.test"], ["http://upgrade.test", "https://upgrade.test"]] {
            let sent = try await cookies(allowing: allowed, fetching: "http://upgrade.test/x")
            #expect(sent.count == 1 && sent.allSatisfy { $0.cookie == "sid=tab-secret" }, "\(allowed): \(sent)")
        }
        // The https form of a URL on port 80 is the one on 443, as HSTS moves it.
        let ported = try await cookies(allowing: ["http://upgrade.test:80", "https://upgrade.test:443"], fetching: "http://upgrade.test/x")
        #expect(ported.count == 1 && ported.allSatisfy { $0.cookie == "sid=tab-secret" }, "\(ported)")
    }
}
