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
/// deciding the row from the latch and offering it every pass while the page stayed held below the strip.
/// (b) A tab switch during the spring to a chat parked in the pane: the decision kept from the terminal (no row) went to
/// the chat. Its frame was set to the held area under the strip, it was offered no row (its page left its one-row
/// header), and at the landing it got the row again: the page changed its header mode twice and laid out twice.
///
/// The rule: a page whose tools are in the tab row holds whole with its strip (the S1 exception, S5/S6), decided for the
/// page shown at the hold's start; while only the content area holds, nothing decides the row again and no page hears a
/// tab-row change; a page shown during the hold keeps its row and its frame; the landing decides the row once.
/// Not covered here: a page that learns its tools in the spring shows them in its own top row under the strip until the
/// landing, as it does at rest until its report arrives. Holding it whole needs to know a report is coming, which only
/// the page can say (its header answers each offer); that is the chat page's change, not the pane's.
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

        init(p1 content: NSView, p2: NSView? = nil, axis: SplitAxis = .horizontal, p1Below: Bool = false) {
            _ = NSApplication.shared
            provider.first["p1"] = content
            provider.first["p2"] = p2
            let (a, b): (SplitNode, SplitNode) = p1Below ? (.leaf("p2"), .leaf("p1")) : (.leaf("p1"), .leaf("p2"))
            let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: axis, ratio: 0.5, a: a, b: b))]
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

    /// (a) A chat offered the row before it reported its tools; Ctrl-Shift-L on its pane. Its tools are not in the row at
    /// the hold's start, so only the content area holds and the strip follows the pane. It reports its tools two frames
    /// into the spring: nothing decides the row again until the landing (the page hears no row change while the area
    /// holds), and the landing gives it the row once, with the content area under the strip in the same pass.
    @Test func aChatThatReportsItsToolsDuringAKeyResizeGetsTheRowOnceAtTheLanding() throws {
        let page = RowPage()
        let rig = Rig(p1: page)
        defer { rig.window.closeAfterTest() }
        let pane = try #require(rig.provider.views["p1"])
        try #require(page.offered.last.map { $0 > 0 } == true, "the chat was not offered the row to learn its tools: \(page.offered)")
        try #require(page.drawnRow == 0 && pane.contentHost.frame.minY > 0, "the chat shares the row before it reported its tools")
        page.offered.removeAll()

        #expect(PaneResize.press("p1", .right, model: rig.model, view: rig.root))
        var frames = 0, areaLetGo: [Int] = []
        while frames < 240, rig.root.advanceFrame(1.0 / 120) {
            frames += 1
            if frames == 2 { page.report(60) }
            rig.root.layoutSubtreeIfNeeded()
            if !pane.contentHost.isHolding { areaLetGo.append(frames) }
        }
        try #require(frames > 3, "the press did not spring (\(frames) frames)")
        #expect(areaLetGo.isEmpty, "only the content area must hold, through the whole spring; it was not held in frames \(areaLetGo.prefix(4))")
        #expect(page.offered.isEmpty, "the chat heard \(page.offered.count) tab-row changes while its area held: \(page.offered.prefix(4))")
        rig.root.layoutSubtreeIfNeeded()
        rig.release()
        #expect(page.offered.count == 1 && page.drawnRow > 0 && pane.contentHost.frame == pane.bounds,
                "the landing did not give the chat the row once: offered \(page.offered), area \(pane.contentHost.frame) in \(pane.bounds)")
        #expect(Self.rowOffStrip(page, in: pane, "after the landing") == nil, "\(Self.rowOffStrip(page, in: pane, "after the landing") ?? "")")
    }

    /// (b) A terminal shows; a chat whose tools share the row is parked in the pane; a key press grows p1; two frames into
    /// the spring the chat's tab is selected. In no frame does the chat draw its row anywhere but in the strip's row, and at
    /// the landing its tools are in the row with the page under the strip. Held on the top edge (the row stays above the
    /// area), the chat hears no row change and keeps its parked frame: it lays out once, at the landing. Held on the bottom
    /// edge (a terminal whose prompt is on its last row; Codex's review of #34247), the area grows above the held content
    /// and would show the chat's row inside it: the chat shows without the row, once, at the held rect, and gets the row
    /// and its rest frame once at the landing.
    /// The presses (b) runs: a horizontal grow, and a vertical grow of p1 under p2 upward: its top edge moves, so its held
    /// area rides the bottom edge (by the edge that stays, and by its terminal's prompt on the last row): the row-sharing
    /// chat's top, above the area, would show under the strip.
    nonisolated static let shownPresses: [Press] = [Press(axis: .horizontal, direction: .right, ridesBottom: false),
                                                    Press(axis: .vertical, direction: .up, ridesBottom: true)]

    /// One press for (b): the split's axis, the arrow on p1, and whether the held content rides the bottom edge.
    nonisolated struct Press: Sendable, CustomTestStringConvertible {
        let axis: SplitAxis
        let direction: LayoutDirection
        let ridesBottom: Bool
        var testDescription: String { "\(axis.rawValue) split, \(direction)\(ridesBottom ? ", held on the bottom edge" : "")" }
    }

    /// A terminal-like content that asks its held area to ride the bottom edge (its prompt on its last row).
    final class BottomContent: NSView, PaneMotionTargeting {
        func paneMotionWillRest(sizeChange: CGSize) -> PaneMotionAnchor { .bottom }
    }

    @Test(arguments: shownPresses)
    func aChatShownDuringAKeyResizeKeepsItsRowAndItsFrameUntilTheLanding(_ press: Press) throws {
        let page = RowPage()
        let rig = Rig(p1: page, axis: press.axis, p1Below: press.ridesBottom)
        defer { rig.window.closeAfterTest() }
        let pane = try #require(rig.provider.views["p1"])
        page.report(60)
        rig.root.layoutSubtreeIfNeeded()
        try #require(page.drawnRow > 0 && pane.contentHost.frame == pane.bounds, "the chat does not share the row at rest: \(page.offered.suffix(2))")
        let terminal: NSView = press.ridesBottom ? BottomContent() : NSView()
        pane.show(terminal)
        rig.root.layoutSubtreeIfNeeded()
        try #require(page.isHidden && page.superview === pane.contentHost, "the chat is not parked in its pane")

        #expect(PaneResize.press("p1", press.direction, model: rig.model, view: rig.root))
        var off: [String] = [], frames = 0
        var shown: (offers: Int, sizes: Int)?
        var heldOnBottom: Bool?
        while frames < 240, rig.root.advanceFrame(1.0 / 120) {
            frames += 1
            if frames == 2 {
                shown = (page.offered.count, page.sizes.count)
                heldOnBottom = pane.contentHost.hold?.bottom
                pane.show(page)
            }
            rig.root.layoutSubtreeIfNeeded()
            if let stray = Self.rowOffStrip(page, in: pane, "frame \(frames)") { off.append(stray) }
        }
        try #require(frames > 3, "the press did not spring (\(frames) frames)")
        let atShow = try #require(shown)
        try #require(heldOnBottom == press.ridesBottom, "SETUP: the area held on the \(heldOnBottom == true ? "bottom" : "top") edge at the switch")
        let duringHold = Array(page.offered.dropFirst(atShow.offers))
        rig.root.layoutSubtreeIfNeeded()
        rig.release()
        if let stray = Self.rowOffStrip(page, in: pane, "after the landing") { off.append(stray) }
        let resized = Array(page.sizes.dropFirst(atShow.sizes))
        if press.ridesBottom {
            #expect(duringHold == [0], "the bottom-held chat heard \(duringHold) during the spring, not one \"no row\"")
            #expect(resized.count <= 2, "the chat laid out \(resized.count) times from its switch to the landing: \(resized)")
        } else {
            #expect(duringHold.isEmpty, "the chat heard tab-row changes during the spring: \(duringHold)")
            #expect(resized.count <= 1, "the chat laid out \(resized.count) times from its switch to the landing: \(resized)")
        }
        #expect(off.isEmpty, "\(off.count) frames drew the chat's tools off the tab row: \(off.prefix(4))")
        #expect(page.drawnRow > 0 && pane.contentHost.frame == pane.bounds,
                "after the landing the chat does not share the row: offered \(page.offered.suffix(3)), area \(pane.contentHost.frame) in \(pane.bounds)")
    }

    /// (c) Codex's review of #34247 at c997a7d3bfe: a chat that shares p2's tab row moves into p1 during a key hold of p1
    /// (a tab dragged across, a script's move): it comes from another pane with p2's row offer. In no frame does it draw
    /// its row off p1's strip row; it hears one "no row" when it arrives, and the landing gives it p1's row once.
    @Test func aChatMovedInFromAnotherPaneDuringAKeyResizeDrawsNoRowUnderTheStrip() throws {
        let page = RowPage()
        let rig = Rig(p1: NSView(), p2: page)
        defer { rig.window.closeAfterTest() }
        let p1 = try #require(rig.provider.views["p1"])
        page.report(60)
        rig.root.layoutSubtreeIfNeeded()
        try #require(page.drawnRow > 0, "SETUP: the chat does not share p2's row at rest: \(page.offered.suffix(2))")

        #expect(PaneResize.press("p1", .right, model: rig.model, view: rig.root))
        var off: [String] = [], frames = 0, offersAtMove = 0
        while frames < 240, rig.root.advanceFrame(1.0 / 120) {
            frames += 1
            if frames == 2 {
                try #require(p1.contentHost.isHolding, "SETUP: p1's area does not hold at the move")
                offersAtMove = page.offered.count
                p1.show(page)
            }
            rig.root.layoutSubtreeIfNeeded()
            if frames >= 2, let stray = Self.rowOffStrip(page, in: p1, "frame \(frames)") { off.append(stray) }
        }
        try #require(frames > 3, "the press did not spring (\(frames) frames)")
        let duringHold = Array(page.offered.dropFirst(offersAtMove))
        rig.root.layoutSubtreeIfNeeded()
        rig.release()
        if let stray = Self.rowOffStrip(page, in: p1, "after the landing") { off.append(stray) }
        #expect(off.isEmpty, "\(off.count) frames drew the moved chat's tools off p1's tab row: \(off.prefix(4))")
        #expect(duringHold == [0], "the moved chat heard \(duringHold) during the hold, not one \"no row\"")
        #expect(page.drawnRow > 0 && p1.contentHost.frame == p1.bounds,
                "after the landing the chat does not share p1's row: offered \(page.offered.suffix(3)), area \(p1.contentHost.frame) in \(p1.bounds)")
    }
}
