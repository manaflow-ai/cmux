import Foundation
import Testing

@testable import CmuxBrowser

/// A `fetch` response's `Set-Cookie` is written into the tab's real cookie
/// store, so it must be one a browser would accept from that response
/// (RFC 6265 section 5.3): a Domain attribute the response's host
/// domain-matches and that is not a public suffix, and no Secure cookie
/// from a plain-http response. Foundation's header parser checks none of
/// that, so without these rules any page an agent fetches could plant a
/// cookie on another site in the user's profile.
@Suite("Browser REPL fetch Set-Cookie scope", .serialized)
struct BrowserReplFetchSetCookieTests {
    /// Answers with the `Set-Cookie` lines the request's query names.
    final class SetCookieProtocol: URLProtocol {
        static let lines: [String: String] = [
            "own": "own=1; Path=/",
            "parent": "parent=2; Domain=cookie-scope.co.uk; Path=/",
            "self": "self=3; Domain=shop.cookie-scope.co.uk; Path=/",
            "other": "planted=4; Domain=bank.example; Path=/",
            "child": "child=5; Domain=deeper.shop.cookie-scope.co.uk; Path=/",
            "suffix": "wide=6; Domain=co.uk; Path=/",
            "secure": "sec=7; Secure; Path=/",
            "plain": "plain=8; Path=/",
        ]

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host?.hasSuffix("cookie-scope.co.uk") == true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else { return }
            let keys = (url.query ?? "").split(separator: ",").map(String.init)
            let header = keys.compactMap { Self.lines[$0] }.joined(separator: ", ")
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/plain", "Set-Cookie": header]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("ok".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    /// Records the cookies the fetcher asks the driver to store.
    final class RecordingDriver: BrowserReplDriver, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [[String: Any]] = []
        var storedNames: Set<String> { lock.withLock { Set(stored.compactMap { $0["name"] as? String }) } }
        var capabilities: [String] { [] }

        func call(method: String, paramsJSON: String) async -> Result<String, BrowserReplDriverError> {
            if method == "cookies.set",
               let params = JSONSerialization.browserReplValue(paramsJSON) as? [String: Any],
               let cookies = params["cookies"] as? [[String: Any]] {
                lock.withLock { stored.append(contentsOf: cookies) }
            }
            return .success(method == "cookies.get" ? "[]" : "null")
        }

        func attach(eventSink: @escaping BrowserReplDriverEventSink) {}
        func detach() {}
    }

    private func fetch(_ url: String) async -> Set<String> {
        let driver = RecordingDriver()
        let fetcher = BrowserReplFetcher(driver: driver, protocolClasses: [SetCookieProtocol.self])
        defer { fetcher.invalidate() }
        let request: [String: Any] = ["url": url, "method": "GET"]
        let result = await fetcher.fetch(requestJSON: JSONSerialization.browserReplString(request) ?? "{}")
        if case .failure(let error) = result { Issue.record("\(url): \(error)") }
        return driver.storedNames
    }

    @Test("Only cookies the response's host may set are stored")
    func storesOnlyCookiesTheHostMaySet() async throws {
        try #require(BrowserReplPublicSuffixList.system.isPublicSuffix("co.uk"), "needs the system Public Suffix List")
        let stored = await fetch("https://shop.cookie-scope.co.uk/x?own,parent,self,other,child,suffix,secure")
        #expect(stored == ["own", "parent", "self", "sec"], "\(stored.sorted())")
    }

    @Test("A Secure cookie from a plain-http response is not stored")
    func secureOnlyFromSecureResponse() async {
        let stored = await fetch("http://shop.cookie-scope.co.uk/x?secure,plain")
        #expect(stored == ["plain"], "\(stored.sorted())")
    }
}
