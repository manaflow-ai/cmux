import Foundation
@testable import CmuxNextPages
@testable import CmuxNextUpdater
@testable import CmuxNextWebUpdates
import Testing

/// The web update safe point with frozen pages (p13-webui-071, p13-webui.md 3.C). With feature
/// `webUpdateReloadOnShow` it asks only the pages the page host shows, so a hidden or frozen page,
/// which cannot answer, never holds the swap; the swap reloads the shown page and leaves the others
/// to reload when they show. Without it every page that holds a document is asked and reloads.
@MainActor @Suite(.serialized)
struct WebUpdatesFrozenPagesTests {
    /// A page as the safe point sees it: whether it shows, what it answers, what the swap did to it.
    @MainActor private final class Page: WebBundlePage {
        let bundleShown: Bool
        let bundleHasDocument = true
        let bundleParked = false
        let bundleLoading = false
        let bundleDocument: URL?
        /// What the page answers when asked; a frozen page cannot answer and would hold the swap.
        let answer: String?
        private(set) var asks = 0
        private(set) var reloads = 0
        private(set) var stale = false

        init(shown: Bool, index: Int, answer: String? = nil, hiddenAnswer: String? = "page.frozen") {
            bundleShown = shown
            bundleDocument = URL(string: "cmux-page://test.page-\(index)/index.html")
            self.answer = shown ? answer : hiddenAnswer
        }

        func askBundleSwap() async -> String? {
            asks += 1
            return answer
        }

        func reloadForBundle() { reloads += 1 }
        func markBundleStale() { stale = true }
    }

    /// The page host: its pages, and the swap as ``WebUIHost`` performs it.
    @MainActor private final class Host: WebBundleHost {
        let pages: [Page]
        let bundleReloadsOnShow: Bool
        init(pages: [Page], reloadsOnShow: Bool = true) {
            self.pages = pages
            bundleReloadsOnShow = reloadsOnShow
        }
        var webBundlePages: [any WebBundlePage] { pages }
        func webBundleDidChange() -> Int { reloadOrMarkStale(webBundlePages) }
    }

    private static let update = URL(fileURLWithPath: "/Support/web-updates/trees/next", isDirectory: true)

    /// Web updates whose look finds the app quiet (the person is away), serving through its own overlay.
    private func webUpdates(_ host: Host) -> WebUpdates {
        let web = WebUpdates()
        web.pages = { host }
        web.overlay = WebBundleOverlay(bases: [])
        web.appGate = { pagesShown in pagesShown ? .askPages : .swap }
        return web
    }

    @Test func oneShownAndFourFrozenPagesGiveOneAskedPageOneReloadAndNoHeldSwap() async {
        let pages = [Page(shown: true, index: 0)] + (1...4).map { Page(shown: false, index: $0) }
        let host = Host(pages: pages)
        let web = webUpdates(host)
        web.ready(Self.update, version: nil)
        await web.look()

        #expect(web.pending == nil, "the swap was held by \(web.heldBy ?? "nothing")")
        #expect(web.overlay.activeTree?.path == Self.update.path)
        #expect(pages.filter { $0.asks > 0 }.count == 1, "a hidden or frozen page was asked")
        #expect(pages[0].asks == 2, "the shown page is asked twice, the second right before the swap")
        #expect(pages.map(\.reloads) == [1, 0, 0, 0, 0])
        #expect(pages.dropFirst().allSatisfy(\.stale))
        #expect(!pages[0].stale)
    }

    @Test func aBusyShownPageStillHoldsTheSwap() async {
        let page = Page(shown: true, index: 0, answer: "selection")
        let web = webUpdates(Host(pages: [page]))
        web.ready(Self.update, version: nil)
        await web.look()
        #expect(web.pending != nil)
        #expect(web.heldBy == "selection")
        #expect(web.overlay.activeTree == nil)
        #expect(page.reloads == 0)
        web.safePoint.cancel()
    }

    @Test func noShownPageSwapsWithoutAskingAndEveryPageWaitsForItsShow() async {
        let pages = (0..<3).map { Page(shown: false, index: $0) }
        let web = webUpdates(Host(pages: pages))
        web.ready(Self.update, version: nil)
        await web.look()
        #expect(web.pending == nil)
        #expect(pages.allSatisfy { $0.asks == 0 && $0.reloads == 0 && $0.stale })
    }

    @Test func withTheFeatureOffEveryPageIsAskedAndReloadsAtTheSwap() async {
        let pages = [Page(shown: true, index: 0)] + (1...2).map { Page(shown: false, index: $0, hiddenAnswer: nil) }
        let web = webUpdates(Host(pages: pages, reloadsOnShow: false))
        web.ready(Self.update, version: nil)
        await web.look()
        #expect(web.pending == nil, "the swap was held by \(web.heldBy ?? "nothing")")
        #expect(pages.allSatisfy { $0.asks == 2 && $0.reloads == 1 && !$0.stale })
    }

    @Test func withTheFeatureOffAHiddenPageThatCannotAnswerHoldsTheSwap() async {
        let pages = [Page(shown: true, index: 0), Page(shown: false, index: 1)]
        let web = webUpdates(Host(pages: pages, reloadsOnShow: false))
        web.ready(Self.update, version: nil)
        await web.look()
        #expect(web.heldBy == "page.frozen")
        #expect(pages.allSatisfy { $0.reloads == 0 })
        web.safePoint.cancel()
    }
}
