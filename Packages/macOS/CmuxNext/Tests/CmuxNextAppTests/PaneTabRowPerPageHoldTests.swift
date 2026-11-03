import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S1B, the review low of #33874 at b75090d0b38 (PR comment 6610452584): a key resize's tab-row
/// decision was kept per PANE, not per PAGE. `PaneContentView.tabRow` was written at rest and read while the content area
/// held, whatever page the pane showed by then, and `paneMotionHoldArea` read it at the hold's start.
///
/// (a) A chat offered the row before it reported its tools (it learns its width from the offer) got the area hold: the
/// strip followed the pane and the page was held below it. When it reported its tools during the spring, the pane went on
/// offering it the row while it kept the page below the strip, so the page drew its tools in its own top row, under the
/// strip, until the landing, and then jumped up under the strip.
/// (b) A tab switch during the spring to a chat parked in the pane: the decision kept from the terminal (no row) went to
/// the chat. Its frame was set to the held area under the strip, it was offered no row (its page left its one-row
/// header), and at the landing it got the row again: the page changed its header mode twice and laid out twice.
///
/// The rule: a page that may draw its tools in the tab row holds whole with its strip (the S1 exception, S5/S6), decided
/// for the page shown at the hold's start; while only the content area holds, no page hears a tab-row change, and a page
/// shown during the hold keeps its row and its frame until the landing, which decides the row for it once.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct PaneTabRowPerPageHoldTests {
    /// A chat's page in the tab row: it learns its tools' width from the first offer (``report(_:)``), draws them in its
    /// top `offered.last` points while it has them, and records every row it is offered and every size it takes.
    final class RowPage: NSView, PaneTabRowSharing, PaneParkableContent {
        var tools: CGFloat = 0
        var need: CGFloat?
        var offered: [CGFloat] = []
        var sizes: [CGSize] = []
        var tabRowToolsWidth: CGFloat? { tools > 0 ? tools : nil }
        var tabRowToolsNeed: CGFloat? { need }
        var onTabRowToolsChange: (() -> Void)?
        func setTabRow(height: CGFloat, trailingInset: CGFloat) { offered.append(height) }
        override func setFrameSize(_ newSize: NSSize) {
            if newSize != frame.size { sizes.append(newSize) }
            super.setFrameSize(newSize)
        }

        /// The page reports its tools' width, as a chat's page does after the pane offers it the row.
        func report(_ width: CGFloat) {
            (tools, need) = (width, width)
            onTabRowToolsChange?()
        }

        /// The points at its top where it draws its tools now: the row it was last offered, while it has tools.
        var drawnRow: CGFloat { tools > 0 ? offered.last ?? 0 : 0 }
    }

    final class Panes: LayoutPaneContentProvider {
        let reveal: LaunchReveal = {
            let reveal = LaunchReveal()
            reveal.markAllReady()
            return reveal
        }()
        var views: [PaneID: PaneContentView] = [:]
        var first: [PaneID: NSView] = [:]

        func makeContentView(for pane: PaneID) -> NSView {
            let tabs = (0..<2).map { TabItem(id: TabID("\(pane.rawValue)-tab\($0)"), title: "Chat \($0)") }
            let view = PaneContentView(stripModel: TabStripModel(tabs: tabs, selectedID: tabs[0].id), reveal: reveal)
            view.show(first[pane] ?? NSView())
            views[pane] = view
            return view
        }
    }

    /// p1 | p2 in a 1200 x 800 window; the test is the clock and runs the landing's after-commit work.
    final class Rig {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        var afterCommit: [@MainActor () -> Void] = []

        init(p1 content: NSView) {
            _ = NSApplication.shared
            provider.first["p1"] = content
            let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))]
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            root.context.afterCommit = { [unowned self] in self.afterCommit.append($0) }
        }

        /// Runs the landing's after-commit work, then the layout pass after it.
        func release() {
            let work = afterCommit
            afterCommit.removeAll()
            for item in work { item() }
            root.layoutSubtreeIfNeeded()
        }
    }

    /// Where `page` draws its tools' row off its pane's tab row, in device pixels of the window; nil when it does not.
    /// The row it draws is its top ``RowPage/drawnRow`` points: it must be the strip's row (the page's top on the strip's
    /// top) or not show at all (cut by the content area).
    static func rowOffStrip(_ page: RowPage, in pane: PaneContentView, _ label: String) -> String? {
        let row = page.drawnRow
        guard row > 0, page.window != nil, !page.isHiddenOrHasHiddenAncestor else { return nil }
        let scale = page.window?.backingScaleFactor ?? 2
        func px(_ value: CGFloat) -> Int { Int((value * scale).rounded()) }
        let top = page.convert(page.bounds, to: nil).maxY
        let shownTop = page.convert(page.visibleRect, to: nil).maxY
        let stripTop = pane.stripView.convert(pane.stripView.bounds, to: nil).maxY
        // None of the drawn row shows: the area cuts it.
        guard px(shownTop) > px(top - row) else { return nil }
        guard px(top) != px(stripTop) else { return nil }
        return "\(label): the page draws its \(row) pt row with its top at \(top), not on the strip's top \(stripTop) (shown up to \(shownTop))"
    }

    /// (a) A chat offered the row before it reported its tools; Ctrl-Shift-L on its pane; it reports its tools during the
    /// spring. In no frame does it draw its row anywhere but in the strip's row, and at the landing its tools are in it.
    @Test func aChatThatReportsItsToolsDuringAKeyResizeDrawsItsRowOnlyInTheStrip() throws {
        let page = RowPage()
        let rig = Rig(p1: page)
        defer { rig.window.closeAfterTest() }
        let pane = try #require(rig.provider.views["p1"])
        try #require(page.offered.last.map { $0 > 0 } == true, "the chat was not offered the row to learn its tools: \(page.offered)")
        try #require(page.drawnRow == 0 && pane.contentHost.frame.minY > 0, "the chat shares the row before it reported its tools")

        #expect(PaneResize.press("p1", .right, model: rig.model, view: rig.root))
        var off: [String] = [], frames = 0
        while frames < 240, rig.root.advanceFrame(1.0 / 120) {
            frames += 1
            if frames == 2 { page.report(60) }
            rig.root.layoutSubtreeIfNeeded()
            if let stray = Self.rowOffStrip(page, in: pane, "frame \(frames)") { off.append(stray) }
        }
        try #require(frames > 3, "the press did not spring (\(frames) frames)")
        rig.root.layoutSubtreeIfNeeded()
        rig.release()
        if let stray = Self.rowOffStrip(page, in: pane, "after the landing") { off.append(stray) }
        #expect(off.isEmpty, "\(off.count) frames drew the chat's tools off the tab row: \(off.prefix(4))")
        #expect(page.drawnRow > 0, "the chat's tools are not in the row after the landing: offered \(page.offered.suffix(3))")
    }

    /// (b) A terminal shows; a chat whose tools share the row is parked in the pane; Ctrl-Shift-L; two frames into the
    /// spring the chat's tab is selected. Until the landing the chat hears no row change and keeps the frame it was parked
    /// at (it lays out only once, at the landing), never draws its row off the strip's row, and at the landing its tools
    /// are in the row with the page under the strip.
    @Test func aChatShownDuringAKeyResizeKeepsItsRowAndItsFrameUntilTheLanding() throws {
        let page = RowPage()
        let rig = Rig(p1: page)
        defer { rig.window.closeAfterTest() }
        let pane = try #require(rig.provider.views["p1"])
        page.report(60)
        rig.root.layoutSubtreeIfNeeded()
        try #require(page.drawnRow > 0 && pane.contentHost.frame == pane.bounds, "the chat does not share the row at rest: \(page.offered.suffix(2))")
        let terminal = NSView()
        pane.show(terminal)
        rig.root.layoutSubtreeIfNeeded()
        try #require(page.isHidden && page.superview === pane.contentHost, "the chat is not parked in its pane")

        #expect(PaneResize.press("p1", .right, model: rig.model, view: rig.root))
        var off: [String] = [], frames = 0
        var shown: (offers: Int, sizes: Int)?
        while frames < 240, rig.root.advanceFrame(1.0 / 120) {
            frames += 1
            if frames == 2 {
                shown = (page.offered.count, page.sizes.count)
                pane.show(page)
            }
            rig.root.layoutSubtreeIfNeeded()
            if let stray = Self.rowOffStrip(page, in: pane, "frame \(frames)") { off.append(stray) }
        }
        try #require(frames > 3, "the press did not spring (\(frames) frames)")
        let atShow = try #require(shown)
        let duringHold = Array(page.offered.dropFirst(atShow.offers))
        rig.root.layoutSubtreeIfNeeded()
        rig.release()
        if let stray = Self.rowOffStrip(page, in: pane, "after the landing") { off.append(stray) }
        #expect(duringHold.isEmpty, "the chat heard tab-row changes during the spring: \(duringHold)")
        let resized = Array(page.sizes.dropFirst(atShow.sizes))
        #expect(resized.count <= 1, "the chat laid out \(resized.count) times from its switch to the landing: \(resized)")
        #expect(off.isEmpty, "\(off.count) frames drew the chat's tools off the tab row: \(off.prefix(4))")
        #expect(page.drawnRow > 0 && pane.contentHost.frame == pane.bounds,
                "after the landing the chat does not share the row: offered \(page.offered.suffix(3)), area \(pane.contentHost.frame) in \(pane.bounds)")
    }
}
