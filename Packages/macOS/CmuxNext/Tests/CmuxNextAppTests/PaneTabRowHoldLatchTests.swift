import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S1, review of #33874 at 9830311fd9b (the chat-in-tab-row gap). A key resize holds only a pane's
/// content area and the pane lays out at its pane's rect in every frame. A page that draws its tools in the tab row (a
/// chat) decides from the pane's width whether they fit there (`PaneTabRowSharing`).
/// The page itself is held until stage S5, so its row must not change while it is held: the decision the hold started
/// with stays until the landing, and at the landing the row and the content area change in the same layout pass.
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
    /// it past that width during the spring. No frame of the spring changes p1's row; the landing does, in one pass.
    @Test func aRowFitThatFlipsDuringAKeyResizeWaitsForTheLanding() throws {
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
        var changed: [String] = [], frames = 0, flipped = false
        while frames < 240, root.advanceFrame(1.0 / 120) {
            root.layoutSubtreeIfNeeded()
            frames += 1
            if pane.bounds.width >= start + 30 { flipped = true }
            if page.offered.contains(where: { $0 > 0 }) { changed.append("frame \(frames): the page was offered the row \(page.offered)") }
            if pane.contentHost.frame.minY <= 0 { changed.append("frame \(frames): the content area grew over the row \(pane.contentHost.frame)") }
        }
        try #require(frames > 3 && flipped, "the press did not spring past the width where the tools fit (\(frames) frames, \(pane.bounds.width) pt)")
        #expect(changed.isEmpty, "the tab row changed while the page was held: \(changed.prefix(4))")

        // The landing: its release lays the pane out once, and the row and the content area change in that pass.
        root.layoutSubtreeIfNeeded()
        for work in afterCommit { work() }
        #expect(page.offered.last.map { $0 > 0 } == true, "the landing did not offer the page the row: \(page.offered.suffix(3))")
        #expect(pane.contentHost.frame == pane.bounds, "the landing did not give the content area the row: \(pane.contentHost.frame) in \(pane.bounds)")
    }
}
