import CmuxNextSettings
import CmuxNextWakeups
import Foundation
@testable import CmuxNextPages
@testable import CmuxNextUpdater
@testable import CmuxNextWebUpdates
import Testing

/// The web update safe point with frozen pages (p13-webui.md 3.C). With feature
/// `webUpdateReloadOnShow` it asks only the pages the page host shows, so a hidden or frozen page,
/// which cannot answer, never holds the swap; the swap reloads the shown page and leaves the others
/// to reload when they show. Without it every page that holds a document is asked and reloads.
/// A stale page that shows is asked first and reloads only when it allows it, so a reload never loses
/// what it holds (``WebUpdates/askShownStale()``).
@MainActor @Suite(.serialized)
struct WebUpdatesFrozenPagesTests {
    /// A page as the safe point sees it: whether it shows, what it answers, what the swap did to it.
    @MainActor private final class Page: WebBundlePage {
        var bundleShown: Bool
        let bundleHasDocument = true
        let bundleParked = false
        let bundleLoading = false
        let bundleDocument: URL?
        /// What the page answers when asked; a frozen page cannot answer and would hold the swap.
        var answer: String?
        private(set) var asks = 0
        private(set) var reloads = 0
        private(set) var bundleStale = false
        var stale: Bool { bundleStale }

        init(shown: Bool, index: Int, answer: String? = nil, hiddenAnswer: String? = "page.frozen") {
            bundleShown = shown
            bundleDocument = URL(string: "cmux-page://test.page-\(index)/index.html")
            self.answer = shown ? answer : hiddenAnswer
        }

        func askBundleSwap() async -> String? {
            asks += 1
            return answer
        }

        func reloadForBundle() {
            reloads += 1
            bundleStale = false
        }
        func markBundleStale() { bundleStale = true }

        /// A tab switch shows the page; it answers `answer` from now on.
        func show(answering answer: String?) {
            bundleShown = true
            self.answer = answer
        }
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

    private static let work = BackgroundWork(label: "test.web-updates-frozen")
    /// The safe point's deadlines, on a scheduler whose wakes nothing fires: each test runs its looks itself.
    private let deadlines = MainDeadlineRig(framed: false)

    /// Web updates whose look finds the app quiet (the person is away), serving through its own overlay.
    private func webUpdates(_ host: Host) -> WebUpdates {
        let web = WebUpdates(overlay: WebBundleOverlay(bases: []))
        // No launch read: nothing starts but the inputs a look reads and the page host.
        web.prepare(UpdatesSettings(), launch: nil, inputs: WebUpdates.Inputs(
            files: Self.work, energy: EnergyPolicySource(), shown: nil, deadlines: deadlines.deadlines,
            appEvents: AppEvents(center: NotificationCenter()), checkNode: nil), pages: { host })
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
        #expect(pages.dropFirst().allSatisfy { $0.stale })
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
        web.safePoint?.cancel()
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

    /// A hidden page holds text in a field its document does not keep: at its show it says so, and it
    /// is not reloaded; it keeps its document and stays stale, and the next quiet look reloads it once
    /// it allows it.
    @Test func aStalePageThatHoldsSomethingAtItsShowIsNotReloadedAndStaysStale() async {
        let pages = [Page(shown: true, index: 0), Page(shown: false, index: 1)]
        let host = Host(pages: pages)
        let web = webUpdates(host)
        web.ready(Self.update, version: nil)
        await web.look()
        #expect(web.pending == nil)
        let hidden = pages[1]
        #expect(hidden.stale && hidden.reloads == 0)

        hidden.show(answering: "field.unsaved")
        await web.askShownStale()
        #expect(hidden.asks == 1, "the page was not asked at its show")
        #expect(hidden.reloads == 0, "the show reloaded a page that held what a reload loses")
        #expect(hidden.stale)
        #expect(web.heldBy == "field.unsaved")
        #expect(web.hasLookWork, "no later look would reload the page")

        // A later look under the same rules: still held, then allowed.
        await web.look()
        #expect(hidden.reloads == 0 && hidden.stale)
        hidden.answer = nil
        await web.look()
        #expect(hidden.reloads == 1)
        #expect(!hidden.stale)
        #expect(!web.hasLookWork)
        #expect(pages[0].reloads == 1, "a page that was not stale reloaded again")
        web.safePoint?.cancel()
    }

    @Test func aStalePageThatHoldsNothingReloadsAtItsShow() async {
        let pages = [Page(shown: true, index: 0), Page(shown: false, index: 1)]
        let web = webUpdates(Host(pages: pages))
        web.ready(Self.update, version: nil)
        await web.look()
        let hidden = pages[1]
        hidden.show(answering: nil)
        await web.askShownStale()
        #expect(hidden.asks == 1)
        #expect(hidden.reloads == 1)
        #expect(!hidden.stale)
        #expect(!web.hasLookWork)
    }

    @Test func aStalePageHiddenAgainBeforeItAnswersIsNotReloaded() async {
        let page = Page(shown: false, index: 0)
        let web = webUpdates(Host(pages: [page]))
        web.ready(Self.update, version: nil)
        await web.look()
        #expect(page.stale)
        // Never shown: the show's ask does nothing.
        await web.askShownStale()
        #expect(page.asks == 0 && page.reloads == 0 && page.stale)
    }

    @Test func withTheFeatureOffAHiddenPageThatCannotAnswerHoldsTheSwap() async {
        let pages = [Page(shown: true, index: 0), Page(shown: false, index: 1)]
        let web = webUpdates(Host(pages: pages, reloadsOnShow: false))
        web.ready(Self.update, version: nil)
        await web.look()
        #expect(web.heldBy == "page.frozen")
        #expect(pages.allSatisfy { $0.reloads == 0 })
        web.safePoint?.cancel()
    }
}
