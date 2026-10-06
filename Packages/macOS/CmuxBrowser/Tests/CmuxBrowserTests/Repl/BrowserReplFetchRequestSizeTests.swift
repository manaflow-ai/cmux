import Foundation
import Testing

@testable import CmuxBrowser

/// One fetch sends at most 64 MiB (the per-call request limit of the
/// session's resource ledger), counted over its URL, headers and decoded
/// body together, so headers cannot take the room the body is refused.
@Suite("Browser REPL fetch request size", .serialized)
struct BrowserReplFetchRequestSizeTests {
    private func fetchRefusal(headerBytes: Int, bodyBytes: Int) async throws -> (BrowserReplDriverError?, Int) {
        let requests = BrowserReplResponseCounter()
        let server = try BrowserReplTestHTTPServer { _, _, _ in
            requests.increment()
            return (200, ["Content-Type": "text/plain"], Data("ok".utf8))
        }
        try await server.start()
        defer { server.stop() }
        let driver = HeldCookiesDriver()
        driver.releaseAll()
        let fetcher = BrowserReplFetcher(driver: driver)
        defer { fetcher.invalidate() }
        var request: [String: Any] = [
            "url": "http://127.0.0.1:\(server.port)/",
            "method": "POST",
            "credentials": "omit",
            "headers": [["X-Large", String(repeating: "a", count: headerBytes)]],
        ]
        if bodyBytes > 0 { request["bodyBase64"] = Data(count: bodyBytes).base64EncodedString() }
        let json = try #require(JSONSerialization.browserReplString(request))
        #expect(BrowserReplFetcher.oversizedRequest(json) == nil, "the pre-parse bound refused it; the test does not reach the full-size check")
        let result = await fetcher.fetch(requestJSON: json)
        guard case .failure(let error) = result else { return (nil, requests.count) }
        return (error, requests.count)
    }

    @Test("A request whose headers pass 64 MiB is refused before it is sent")
    func headerHeavyRequestIsRefused() async throws {
        let (error, sent) = try await fetchRefusal(headerBytes: 70 << 20, bodyBytes: 0)
        #expect(error?.code == "invalid", "\(String(describing: error))")
        #expect(error?.message.contains("64 MiB") == true, "\(String(describing: error))")
        #expect(sent == 0)
    }

    @Test("Headers and body that pass 64 MiB together are refused before they are sent")
    func headersPlusBodyAreRefused() async throws {
        let (error, sent) = try await fetchRefusal(headerBytes: 30 << 20, bodyBytes: 40 << 20)
        #expect(error?.code == "invalid", "\(String(describing: error))")
        #expect(error?.message.contains("64 MiB") == true, "\(String(describing: error))")
        #expect(sent == 0)
    }
}
