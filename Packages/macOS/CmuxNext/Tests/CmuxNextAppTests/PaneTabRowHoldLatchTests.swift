import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// A page that draws its tools in the tab row (a chat) decides from the pane's width whether they fit there
/// (`PaneTabRowSharing`). In a key resize the pane lays out in every frame as at rest (PANE RESIZE ALL KINDS, Lawrence
/// 2026-11-11), so a fit that flips during the spring flips in that frame, and the row and the content area change in
/// the same layout pass. History (FRAME OWNER S1, review of #33874 at 9830311fd9b): while the page was held through the
/// spring, the decision waited for the landing.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct PaneTabRowHoldLatchTests {
    /// A page whose tools need `need` points of the tab row: every row it is offered, in order.
    final class RowPage: NSView, PaneTabRowSharing {
        var need: CGFloat = 0
        var offered: [CGFloat] = []
        var tabRowToolsWidth: CGFloat? { need }
        var tabRowToolsNeed: CGFloat? { need }
        var onTabRowToolsChange: (() -> Void)?
        func setTabRow(height: CGFloat, trailingInset: CGFloat) { offered.append(height) }
    }

    final class Panes: LayoutPaneContentProvider {
        let reveal: LaunchReveal = {
            let reveal = LaunchReveal()
            reveal.markAllReady()
            return reveal
        }()
        var views: [PaneID: PaneContentView] = [:]
        let page = RowPage()

        func makeContentView(for pane: PaneID) -> NSView {
            let tabs = (0..<2).map { TabItem(id: TabID("\(pane.rawValue)-tab\($0)"), title: "Chat \($0)") }
            let view = PaneContentView(stripModel: TabStripModel(tabs: tabs, selectedID: tabs[0].id), reveal: reveal)
            view.show(pane == "p1" ? page : NSView())
            views[pane] = view
            return view
        }
    }

    /// p1 | p2, a chat in p1 whose tools fit its tab row only once p1 is wider than at rest; Ctrl-Shift-L on p1 grows
    /// it past that width during the spring. In every frame the page has the row exactly when the content area covers
    /// it (one pass), the flip is in a frame of the spring, and the landing changes nothing.
    @Test func aRowFitThatFlipsDuringAKeyResizeFlipsInThatFrameInOnePass() throws {
        _ = NSApplication.shared
        let provider = Panes()
        let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))]
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: "p1")
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.closeAfterTest() }
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        var afterCommit: [@MainActor () -> Void] = []
        root.context.afterCommit = { afterCommit.append($0) }
        let pane = try #require(provider.views["p1"]), page = provider.page
        // The tools fit once the row is 30 pt wider than it is at rest (the press grows p1 by about 60 pt).
        let start = pane.bounds.width
        page.need = (start + 30) / 2
        pane.needsLayout = true
        root.layoutSubtreeIfNeeded()
        try #require(page.offered.last == 0 && pane.contentHost.frame.minY > 0, "the tools take the row at rest: \(page.offered.suffix(2))")
        page.offered.removeAll()

        #expect(PaneResize.press("p1", .right, model: model, view: root))
        var off: [String] = [], frames = 0, grewPast = false, flippedAt: Int?
        while frames < 240, root.advanceFrame(1.0 / 120) {
            root.layoutSubtreeIfNeeded()
            frames += 1
            if pane.bounds.width >= start + 30 { grewPast = true }
            let offered = (page.offered.last ?? 0) > 0, covers = pane.contentHost.frame.minY <= 0
            if offered != covers { off.append("frame \(frames): the page \(offered ? "has" : "has not") the row, the content area \(covers ? "covers" : "does not cover") it") }
            if page.frame != pane.contentHost.bounds { off.append("frame \(frames): the page at \(page.frame) in an area of \(pane.contentHost.bounds)") }
            if offered, flippedAt == nil { flippedAt = frames }
        }
        try #require(frames > 3 && grewPast, "the press did not spring past the width where the tools fit (\(frames) frames, \(pane.bounds.width) pt)")
        #expect(off.isEmpty, "the row and the content area did not change in one pass: \(off.prefix(4))")
        #expect(flippedAt != nil, "the page did not get the row in a frame of the spring; it waited for the landing")

        // The landing and its release change nothing: the row is the page's and the content area covers it.
        root.layoutSubtreeIfNeeded()
        let offers = page.offered.filter { $0 <= 0 }.count
        for work in afterCommit { work() }
        root.layoutSubtreeIfNeeded()
        #expect(page.offered.last.map { $0 > 0 } == true && page.offered.filter { $0 <= 0 }.count == offers,
                "the landing took the row from the page: \(page.offered.suffix(3))")
        #expect(pane.contentHost.frame == pane.bounds, "the content area does not cover the row after the landing: \(pane.contentHost.frame) in \(pane.bounds)")
    }
}
