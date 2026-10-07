import Foundation
import Testing

@testable import CmuxBrowser

/// A fetch reads the tab's cookies (an await) after its URL is checked. The
/// domain policy can narrow during that await; the request must then never
/// reach the destination the narrowed policy blocks, first or as a hop.
@Suite("Browser REPL fetch policy narrowing", .serialized)
struct BrowserReplFetchPolicyNarrowingTests {
    /// The domain policy check the session gives the fetcher, blocking every
    /// URL that contains `blockedFragment` once `narrow` has run.
    final class NarrowingPolicy: @unchecked Sendable {
        private let lock = NSLock()
        private var blockedFragment: String?

        func narrow(blocking fragment: String) {
            lock.withLock { blockedFragment = fragment }
        }

        func reason(_ url: String) -> String? {
            guard let fragment = lock.withLock({ blockedFragment }), url.contains(fragment) else { return nil }
            return "narrowed while the request waited"
        }
    }

    @Test("A policy narrowed while a fetch reads its cookies blocks the request before it is sent")
    func narrowingDuringCookieLookupBlocksFirstRequest() async throws {
        let requests = BrowserReplResponseCounter()
        let server = try BrowserReplTestHTTPServer { _, _, _ in
            requests.increment()
            return (200, [:], Data("sent".utf8))
        }
        try await server.start()
        defer { server.stop() }
        let driver = HeldCookiesDriver()
        let fetcher = BrowserReplFetcher(driver: driver)
        defer { fetcher.invalidate() }
        let policy = NarrowingPolicy()
        fetcher.setBlockReason { policy.reason($0) }

        let url = "http://127.0.0.1:\(server.port)/target"
        let request: [String: Any] = ["url": url, "method": "GET", "headers": [] as [[String]]]
        async let result = fetcher.fetch(requestJSON: JSONSerialization.browserReplString(request) ?? "{}")
        // The URL passed the first check; the fetch now waits for cookies.
        await driver.waitForEntries(1)
        policy.narrow(blocking: ":\(server.port)/")
        driver.releaseAll()

        guard case .failure(let error) = await result else {
            Issue.record("the request was sent after the policy blocked its URL")
            return
        }
        #expect(error.code == "blocked", "\(error)")
        #expect(requests.count == 0, "the blocked destination received \(requests.count) request(s)")
    }

    @Test("A policy narrowed while a redirect hop reads its cookies blocks the hop before it is followed")
    func narrowingDuringCookieLookupBlocksRedirectHop() async throws {
        let landed = BrowserReplResponseCounter()
        let landing = try BrowserReplTestHTTPServer { _, _, _ in
            landed.increment()
            return (200, [:], Data("landed".utf8))
        }
        try await landing.start()
        defer { landing.stop() }
        let start = try BrowserReplTestHTTPServer { _, _, _ in
            (302, ["Location": "http://127.0.0.1:\(landing.port)/landing"], Data())
        }
        try await start.start()
        defer { start.stop() }
        let driver = HeldCookiesDriver()
        let fetcher = BrowserReplFetcher(driver: driver)
        defer { fetcher.invalidate() }
        let policy = NarrowingPolicy()
        fetcher.setBlockReason { policy.reason($0) }

        // `same-origin` for the landing origin: the first request reads no
        // cookies, so the only cookie lookup is the redirect hop's.
        let request: [String: Any] = [
            "url": "http://127.0.0.1:\(start.port)/start",
            "method": "GET",
            "headers": [] as [[String]],
            "credentials": "same-origin",
            "origin": "http://127.0.0.1:\(landing.port)",
        ]
        async let result = fetcher.fetch(requestJSON: JSONSerialization.browserReplString(request) ?? "{}")
        // The hop passed the redirect check; it now waits for cookies.
        await driver.waitForEntries(1)
        policy.narrow(blocking: ":\(landing.port)/")
        driver.releaseAll()

        guard case .failure(let error) = await result else {
            Issue.record("the redirect hop was followed after the policy blocked its URL")
            return
        }
        #expect(error.code == "blocked", "\(error)")
        #expect(landed.count == 0, "the blocked hop received \(landed.count) request(s)")
    }
}
