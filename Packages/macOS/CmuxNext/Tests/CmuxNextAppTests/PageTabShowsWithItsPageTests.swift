import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextPages
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// 2026-11-16, Settings still opens late: from Home's dock, Cmd-, showed the Settings tab in its new
/// column 150-190 ms before the page drew under it (cmux-lawrence-2). A new pane whose first content is a
/// page that has not painted keeps its tab strip invisible until the page paints: the tab and its page
/// show in one frame. A page that never paints still shows its tab after 250 ms.
@MainActor @Suite(.serialized, .closesItsWindows) struct PageTabShowsWithItsPageTests {
    private final class Column {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let pane: PaneContentView
        let page: PageWebView

        init() throws {
            window.isReleasedWhenClosed = false
            let reveal = LaunchReveal()
            reveal.markAllReady()
            pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("settings"), title: "Settings")]), reveal: reveal)
            pane.frame = window.contentLayoutRect
            window.contentView = pane
            window.orderFrontRegardless()
            pane.layoutSubtreeIfNeeded()
            page = try #require(PageWebView(descriptor: .files, routes: []))
        }

        @discardableResult
        func showPage() -> InternalPageView {
            let view = InternalPageView(key: "tab-with-page", page: .settings, content: page)
            pane.show(view)
            pane.layoutSubtreeIfNeeded()
            return view
        }

        func close() {
            page.close()
            window.close()
        }
    }

    @Test(.timeLimit(.minutes(1))) func aNewPanesTabWaitsForItsPagesFirstFrame() throws {
        let column = try Column()
        defer { column.close() }
        #expect(column.pane.stripView.alphaValue == 1, "the strip shows before the pane has content")

        column.showPage()

        #expect(!column.page.hasPainted)
        #expect(column.pane.stripView.alphaValue == 0, "the Settings tab showed before its page drew")
        column.page.notePainted()
        #expect(column.pane.stripView.alphaValue == 1, "the tab did not show with its page's first frame")
    }

    /// The snapshot 203 ms after Cmd-, on cmux-lawrence-2 (2cad95e): the reclaimed page's stale, narrow render showed
    /// in the new column with no tab, 25 ms before the tab and the page's first frame. A new pane has no outgoing view
    /// for PanePaintHold to keep, so nothing kept the page clear: the page waits with its tab, and both show at once.
    @Test(.timeLimit(.minutes(1))) func aNewPanesPageWaitsWithItsTab() throws {
        let column = try Column()
        defer { column.close() }

        let view = column.showPage()

        #expect(view.alphaValue == 0, "the page showed before its first frame, with no tab above it")
        #expect(column.pane.stripView.alphaValue == 0)
        column.page.notePainted()
        #expect(view.alphaValue == 1, "the page did not show with its first frame")
        #expect(column.pane.stripView.alphaValue == 1, "the tab did not show with its page")
    }

    @Test(.timeLimit(.minutes(1))) func aPageThatNeverPaintsShowsItsTabAfterTheLimit() async throws {
        let column = try Column()
        defer { column.close() }

        column.showPage()
        #expect(column.pane.stripView.alphaValue == 0, "the Settings tab showed before its page drew")

        let start = ContinuousClock.now
        while column.pane.stripView.alphaValue == 0, ContinuousClock.now - start < .seconds(5) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(column.pane.stripView.alphaValue == 1, "a page that never paints kept its tab hidden")
        #expect(ContinuousClock.now - start < .seconds(2))
    }
}
