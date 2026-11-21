import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// A page that draws its tools in the tab row (a chat) in a key resize. Since PANE RESIZE ALL KINDS (Lawrence 2026-11-11:
/// "all must have smooth transition") the pane lays out in every frame of a key resize as it does at rest, so the row is
/// decided for the page shown in that frame, in that frame's pass, with the content area placed in the same pass.
///
/// History (FRAME OWNER S1B, the review low of #33874 at b75090d0b38, PR comment 6610452584): while the page was held
/// through the spring, the row decision was kept per PANE and went to whatever page the pane showed by then: (a) a chat
/// that reported its tools during the spring was offered the row while it stayed held below the strip; (b) a chat shown
/// by a tab switch during the spring got the terminal's "no row", then the row again at the landing; (c) a chat moved in
/// from another pane came with that pane's row.
///
/// The rule these pin: in no frame does a page draw its tools' row anywhere but in its pane's strip row, the page has its
/// area's size in every frame it shows, and after the landing its tools are in the row.
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

    /// (a) A chat offered the row before it reported its tools; Ctrl-Shift-L on its pane. It reports its tools two frames
    /// into the spring: that frame's pass gives it the row with the content area under the strip, as at rest, and in no
    /// frame does it draw its row off the strip's.
    @Test func aChatThatReportsItsToolsDuringAKeyResizeGetsTheRowInThatFrame() throws {
        let page = RowPage()
        let rig = Rig(p1: page)
        defer { rig.window.closeAfterTest() }
        let pane = try #require(rig.provider.views["p1"])
        try #require(page.offered.last.map { $0 > 0 } == true, "the chat was not offered the row to learn its tools: \(page.offered)")
        try #require(page.drawnRow == 0 && pane.contentHost.frame.minY > 0, "the chat shares the row before it reported its tools")

        #expect(PaneResize.press("p1", .right, model: rig.model, view: rig.root))
        var frames = 0, off: [String] = []
        while frames < 240, rig.root.advanceFrame(1.0 / 120) {
            frames += 1
            if frames == 2 { page.report(60) }
            rig.root.layoutSubtreeIfNeeded()
            if let stray = Self.rowOffStrip(page, in: pane, "frame \(frames)") { off.append(stray) }
            if page.frame != pane.contentHost.bounds { off.append("frame \(frames): the chat at \(page.frame) in an area of \(pane.contentHost.bounds)") }
            if frames >= 2, page.drawnRow <= 0 || pane.contentHost.frame != pane.bounds {
                off.append("frame \(frames): the chat's tools are not in the row: offered \(page.offered.suffix(2)), area \(pane.contentHost.frame) in \(pane.bounds)")
            }
        }
        try #require(frames > 3, "the press did not spring (\(frames) frames)")
        rig.root.layoutSubtreeIfNeeded()
        rig.release()
        if let stray = Self.rowOffStrip(page, in: pane, "after the landing") { off.append(stray) }
        #expect(off.isEmpty, "\(off.count) frames off: \(off.prefix(4))")
        #expect(page.drawnRow > 0 && pane.contentHost.frame == pane.bounds,
                "after the landing the chat does not share the row: offered \(page.offered.suffix(3)), area \(pane.contentHost.frame) in \(pane.bounds)")
    }

    /// (b) A terminal shows; a chat whose tools share the row is parked in the pane; a key press grows p1; two frames into
    /// the spring the chat's tab is selected. In no frame does the chat draw its row anywhere but in the strip's row, it has
    /// its area's size in every frame from the switch on, and after the landing its tools are in the row.
    /// The presses (b) runs: a horizontal grow, and a vertical grow of p1 under p2 upward (its top edge moves, and its
    /// terminal's prompt is on the last row).
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
    func aChatShownDuringAKeyResizeDrawsItsRowOnlyInTheStripsRow(_ press: Press) throws {
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
        while frames < 240, rig.root.advanceFrame(1.0 / 120) {
            frames += 1
            if frames == 2 { pane.show(page) }
            rig.root.layoutSubtreeIfNeeded()
            if let stray = Self.rowOffStrip(page, in: pane, "frame \(frames)") { off.append(stray) }
            if frames >= 2, page.frame != pane.contentHost.bounds { off.append("frame \(frames): the chat at \(page.frame) in an area of \(pane.contentHost.bounds)") }
        }
        try #require(frames > 3, "the press did not spring (\(frames) frames)")
        rig.root.layoutSubtreeIfNeeded()
        let landed = page.sizes.count
        rig.release()
        if let stray = Self.rowOffStrip(page, in: pane, "after the landing") { off.append(stray) }
        #expect(off.isEmpty, "\(off.count) frames off: \(off.prefix(4))")
        #expect(page.sizes.count == landed, "the chat changed size after the landing's frame: \(page.sizes.dropFirst(landed))")
        #expect(page.drawnRow > 0 && pane.contentHost.frame == pane.bounds,
                "after the landing the chat does not share the row: offered \(page.offered.suffix(3)), area \(pane.contentHost.frame) in \(pane.bounds)")
    }

    /// (c) Codex's review of #34247 at c997a7d3bfe: a chat that shares p2's tab row moves into p1 during a key resize of p1
    /// (a tab dragged across, a script's move): it comes from another pane with p2's row offer. In no frame does it draw
    /// its row off p1's strip row, and it has p1's row from the frame it arrives in.
    @Test func aChatMovedInFromAnotherPaneDuringAKeyResizeDrawsNoRowUnderTheStrip() throws {
        let page = RowPage()
        let rig = Rig(p1: NSView(), p2: page)
        defer { rig.window.closeAfterTest() }
        let p1 = try #require(rig.provider.views["p1"])
        page.report(60)
        rig.root.layoutSubtreeIfNeeded()
        try #require(page.drawnRow > 0, "SETUP: the chat does not share p2's row at rest: \(page.offered.suffix(2))")

        #expect(PaneResize.press("p1", .right, model: rig.model, view: rig.root))
        var off: [String] = [], frames = 0
        while frames < 240, rig.root.advanceFrame(1.0 / 120) {
            frames += 1
            if frames == 2 {
                try #require(p1.contentHost.isHolding, "SETUP: p1 is not on the key hold at the move")
                p1.show(page)
            }
            rig.root.layoutSubtreeIfNeeded()
            if frames >= 2, let stray = Self.rowOffStrip(page, in: p1, "frame \(frames)") { off.append(stray) }
            if frames >= 2, page.frame != p1.contentHost.bounds { off.append("frame \(frames): the chat at \(page.frame) in an area of \(p1.contentHost.bounds)") }
        }
        try #require(frames > 3, "the press did not spring (\(frames) frames)")
        rig.root.layoutSubtreeIfNeeded()
        rig.release()
        if let stray = Self.rowOffStrip(page, in: p1, "after the landing") { off.append(stray) }
        #expect(off.isEmpty, "\(off.count) frames drew the moved chat's tools off p1's tab row or off its area: \(off.prefix(4))")
        #expect(page.drawnRow > 0 && p1.contentHost.frame == p1.bounds,
                "after the landing the chat does not share p1's row: offered \(page.offered.suffix(3)), area \(p1.contentHost.frame) in \(p1.bounds)")
    }
}
