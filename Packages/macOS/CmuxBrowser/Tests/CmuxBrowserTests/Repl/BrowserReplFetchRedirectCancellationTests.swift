import Foundation
import Testing

@testable import CmuxBrowser

/// A redirect hop reads the tab's cookies through the driver before it is
/// followed. That work belongs to the fetch: cancelling the fetch (its
/// cell timed out) or invalidating the fetcher (its session closed)
/// cancels the hop's driver call, and the fetch returns only after the
/// hop's work ended, so it never outlives the fetch's slot.
@Suite("Browser REPL fetch redirect cancellation", .serialized)
struct BrowserReplFetchRedirectCancellationTests {
    /// A fetch whose first request carries its own Cookie header (so only
    /// the redirect hop reads cookies) and whose redirect hop's
    /// `cookies.get` is held by `driver`.
    private func startRedirectFetch(
        server: BrowserReplTestHTTPServer,
        fetcher: BrowserReplFetcher,
        driver: HeldCookiesDriver
    ) async -> Task<Result<String, BrowserReplDriverError>, Never> {
        let request: [String: Any] = [
            "url": "http://127.0.0.1:\(server.port)/start",
            "method": "GET",
            "headers": [["Cookie", "sid=agent"]],
            "credentials": "include",
        ]
        let json = JSONSerialization.browserReplString(request) ?? "{}"
        let fetch = Task { await fetcher.fetch(requestJSON: json) }
        await driver.waitForEntries(1)
        return fetch
    }

    private func redirectServer() throws -> BrowserReplTestHTTPServer {
        try BrowserReplTestHTTPServer { path, _, port in
            path == "/start"
                ? (302, ["Location": "http://127.0.0.1:\(port)/end"], Data())
                : (200, [:], Data("end".utf8))
        }
    }

    @Test("Cancelling a fetch cancels its redirect hop's cookie call before the fetch returns")
    func cancellingFetchCancelsRedirectCookieCall() async throws {
        let server = try redirectServer()
        try await server.start()
        defer { server.stop() }
        let driver = HeldCookiesDriver()
        defer { driver.releaseAll() }
        let fetcher = BrowserReplFetcher(driver: driver)
        defer { fetcher.invalidate() }

        let fetch = await startRedirectFetch(server: server, fetcher: fetcher, driver: driver)
        fetch.cancel()
        let result = await fetch.value
        #expect(driver.cancelledCount == 1, "the fetch returned while its redirect hop's cookie call was still running")
        guard case .failure(let error) = result else {
            Issue.record("a cancelled fetch succeeded: \(result)")
            return
        }
        #expect(error.code == "cancelled", "\(error)")
    }

    @Test("Invalidating the fetcher cancels a redirect hop's cookie call before the fetch returns")
    func invalidatingFetcherCancelsRedirectCookieCall() async throws {
        let server = try redirectServer()
        try await server.start()
        defer { server.stop() }
        let driver = HeldCookiesDriver()
        defer { driver.releaseAll() }
        let fetcher = BrowserReplFetcher(driver: driver)

        let fetch = await startRedirectFetch(server: server, fetcher: fetcher, driver: driver)
        fetcher.invalidate()
        let result = await fetch.value
        #expect(driver.cancelledCount == 1, "the fetch returned while its redirect hop's cookie call was still running")
        guard case .failure = result else {
            Issue.record("a fetch of a closed session succeeded: \(result)")
            return
        }
    }
}
