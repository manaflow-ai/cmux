@testable import CmuxNextPages
import Foundation
import Testing

/// A reserved `cmux.` page that ships in this module's bundle (Resources/pages/<resource>) is
/// served by the WebKit host from that bundled root, whether or not its id is in the first-party
/// table: the table widens a CSP and lists Chromium-tab pages, it does not gate the WebKit host.
/// Pinned on the CodeRouter page (cmux.coderouter, not in the table).
@MainActor
@Suite struct PageReservedServeTests {
    @Test func theCodeRouterPageIsServedFromItsBundle() async throws {
        let page = PageDescriptor.coderouter
        #expect(PageID.isReserved(page.id))
        let root = try #require(PageSchemeHandler.bundledRoot(for: page))
        #expect(PageWebView.servedRoot(for: page)?.standardizedFileURL == root.standardizedFileURL)
        #expect(PageWebView.mayServe(page, from: root))
        // The real host view accepts it (its init refuses a root mayServe rejects).
        #expect(PageWebView(descriptor: page, routes: []) != nil)
        // The real scheme handler answers the page document with the bundle and the strict CSP.
        let handler = PageSchemeHandler(page: page, root: root)
        let url = try #require(URL(string: "cmux-page://cmux.coderouter/"))
        let reply = try #require(await handler.reply(to: url))
        #expect(reply.response.statusCode == 200)
        #expect(reply.response.value(forHTTPHeaderField: "Content-Security-Policy") == PageCSP.strict.header)
        #expect(String(decoding: reply.body, as: UTF8.self).contains("data-cmux-page=\"coderouter\""))
        // Another reserved root is still refused.
        #expect(!PageWebView.mayServe(page, from: URL(fileURLWithPath: NSTemporaryDirectory())))
    }
}
