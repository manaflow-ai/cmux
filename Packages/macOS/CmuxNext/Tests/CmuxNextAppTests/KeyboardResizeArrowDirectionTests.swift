import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR KEYS (lead decision, STATUS 8923; Lawrence asked the lead to decide): Resize Pane Left/Right
/// (Ctrl-Shift-H/L, Ctrl-Cmd-Left/Right) moves the divider in the arrow's direction, as Ghostty's `resize_split` does,
/// in a scrolling strip too. One press moves exactly one divider one step; only the two sides of that divider change;
/// nothing else on screen moves. Before: a strip column with no horizontal split grew or shrank on its own (Right grew
/// the focused column): the last column's left edge, the divider a person sees, moved LEFT (the strip kept the column
/// at the viewport's edge), and the columns after a middle one moved with it. A right dock grew with Right: its inner
/// edge moved left.
@MainActor
@Suite(.closesItsWindows)
struct KeyboardResizeArrowDirectionTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: LayoutPaneID) -> NSView { NSView() }
    }

    final class Rig {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        var ended: [LayoutIntent] = []

        init(_ columns: [LayoutColumn], focus: LayoutPaneID, animates: Bool = false) {
            _ = NSApplication.shared
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s",
                                focusedPane: focus)
            root = LayoutRootView(model: model, contentProvider: provider)
            // Off: each press lands in its own turn (the springs have their own test below).
            root.context.reduceMotionOverride = !animates
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered,
                              defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            model.intentHandler = { [unowned self] intent in
                if case .setColumnWidth(_, _, _, _, .ended) = intent { ended.append(intent) }
            }
        }

        var screen: ScreenContentView { get throws { try #require(root.screenViews["s"]) } }

        /// Every pane's frame as the screen shows it now.
        func shown() throws -> [LayoutPaneID: CGRect] {
            let screen = try screen
            var frames: [LayoutPaneID: CGRect] = [:]
            for pane in model.screens[0].layout.panes { frames[pane] = try #require(screen.displayedFrame(of: pane), "\(pane) shows no frame") }
            return frames
        }

        /// One press, landed.
        @discardableResult
        func press(_ pane: LayoutPaneID, _ direction: LayoutDirection) -> Bool {
            let moved = PaneResize.press(pane, direction, model: model, view: root)
            var frames = 0
            while frames < 240, root.advanceFrame(1.0 / 120) { frames += 1 }
            root.layoutSubtreeIfNeeded()
            return moved
        }

        /// One step of a column press in points: 5% of the strip.
        var step: CGFloat { (root.bounds.width - root.context.style.stripGap) * CGFloat(PaneResize.step) }
    }

    static func columns(_ widths: [Double]) -> [LayoutColumn] {
        widths.enumerated().map { LayoutColumn(id: LayoutColumnID("c\($0.offset)"), width: $0.element, root: .leaf(LayoutPaneID("p\($0.offset)"))) }
    }

    /// A press moves the divider between `left` and `right` by one step toward `direction` and changes nothing else on
    /// screen: every other pane edge, the other columns and the strip's offset stay.
    static func expectOnlyTheDividerMoved(_ before: [LayoutPaneID: CGRect], _ after: [LayoutPaneID: CGRect], left: LayoutPaneID, right: LayoutPaneID,
                                          direction: LayoutDirection, step: CGFloat, sourceLocation: SourceLocation = #_sourceLocation) {
        let sign: CGFloat = direction == .right ? 1 : -1
        let leftMove = (after[left]?.maxX ?? .nan) - (before[left]?.maxX ?? .nan)
        let rightMove = (after[right]?.minX ?? .nan) - (before[right]?.minX ?? .nan)
        #expect(abs(leftMove - sign * step) <= 1, "the divider's left side moved \(leftMove), want \(sign * step)", sourceLocation: sourceLocation)
        #expect(abs(rightMove - sign * step) <= 1, "the divider's right side moved \(rightMove), want \(sign * step)", sourceLocation: sourceLocation)
        #expect(abs((after[left]?.minX ?? .nan) - (before[left]?.minX ?? .nan)) < 0.01,
                "\(left)'s left edge moved: \(before[left]?.minX ?? .nan) -> \(after[left]?.minX ?? .nan)", sourceLocation: sourceLocation)
        #expect(abs((after[right]?.maxX ?? .nan) - (before[right]?.maxX ?? .nan)) < 0.01,
                "\(right)'s right edge moved: \(before[right]?.maxX ?? .nan) -> \(after[right]?.maxX ?? .nan)", sourceLocation: sourceLocation)
        for (pane, frame) in before where pane != left && pane != right {
            #expect(after[pane] == frame, "\(pane) moved: \(frame) -> \(String(describing: after[pane]))", sourceLocation: sourceLocation)
        }
    }

    // MARK: Strip columns

    /// The last column has no right neighbor: its left edge is the divider, and it moves with the arrow.
    @Test(arguments: [LayoutDirection.right, .left])
    func theLastColumnMovesItsLeftDivider(direction: LayoutDirection) throws {
        let rig = Rig(Self.columns([0.5, 0.5]), focus: "p1")
        defer { rig.window.closeAfterTest() }
        let before = try rig.shown()
        #expect(rig.press("p1", direction))
        Self.expectOnlyTheDividerMoved(before, try rig.shown(), left: "p0", right: "p1", direction: direction, step: rig.step)
    }

    /// A column with a right neighbor moves its right edge, and the columns after the pair stay where they are.
    @Test(arguments: [LayoutDirection.right, .left])
    func aColumnWithARightNeighborMovesItsRightEdgeAndNothingAfterIt(direction: LayoutDirection) throws {
        let rig = Rig(Self.columns([0.3, 0.3, 0.3]), focus: "p1")
        defer { rig.window.closeAfterTest() }
        let before = try rig.shown()
        #expect(rig.press("p1", direction))
        Self.expectOnlyTheDividerMoved(before, try rig.shown(), left: "p1", right: "p2", direction: direction, step: rig.step)
    }

    /// A strip wider than the window, the last column focused (the strip shows its end): the strip offset stays.
    @Test(arguments: [LayoutDirection.right, .left])
    func anOverflowingStripKeepsItsOffset(direction: LayoutDirection) throws {
        let rig = Rig(Self.columns([0.5, 0.5, 0.5]), focus: "p2")
        defer { rig.window.closeAfterTest() }
        let before = try rig.shown()
        let offset = try rig.screen.scroll.target
        #expect(rig.press("p2", direction))
        #expect(try rig.screen.scroll.target == offset, "the press scrolled the strip")
        Self.expectOnlyTheDividerMoved(before, try rig.shown(), left: "p1", right: "p2", direction: direction, step: rig.step)
    }

    /// The divider at the edge of the window (the right neighbor is off screen) cannot move out of it: the press is
    /// refused as at a minimum width, and nothing moves. Left still moves it, into the window.
    @Test func aDividerAtTheWindowsEdgeDoesNotMoveOutOfIt() throws {
        // The strip shows its start (focus on p0), then a click focuses p1: p0 and p1 fill the window, p2 is past it.
        let rig = Rig(Self.columns([0.5, 0.5, 0.5]), focus: "p0")
        defer { rig.window.closeAfterTest() }
        rig.model.focus("p1", source: .pointer)
        rig.root.syncWithModel()
        let before = try rig.shown()
        // p1 shows whole, and the divider (the gap from p1's right edge to p2's left edge) ends at the window's edge.
        let edge = try rig.screen.bounds.maxX
        let p1 = try #require(before["p1"]), p2 = try #require(before["p2"])
        try #require(p1.maxX <= edge + 0.01 && abs(p2.minX - edge) <= 0.5, "the divider between p1 and p2 is not at the window's edge: \(before)")
        #expect(!rig.press("p1", .right), "the press moved the divider out of the window, or scrolled the strip")
        #expect(try rig.shown() == before)
        #expect(rig.ended.isEmpty)
        #expect(rig.press("p1", .left))
        Self.expectOnlyTheDividerMoved(before, try rig.shown(), left: "p1", right: "p2", direction: .left, step: rig.step)
    }

    /// Every frame of the press's spring: the divider only moves toward the arrow, and the outer edges never move.
    @Test func everyFrameOfThePressMovesTheDividerTowardTheArrow() throws {
        let rig = Rig(Self.columns([0.5, 0.5]), focus: "p1", animates: true)
        defer { rig.window.closeAfterTest() }
        let start = try rig.shown()
        #expect(PaneResize.press("p1", .right, model: rig.model, view: rig.root))
        var last = try #require(start["p0"]).maxX, frames = 0
        while frames < 240, rig.root.advanceFrame(1.0 / 120) {
            rig.root.layoutSubtreeIfNeeded()
            let now = try rig.shown()
            let divider = try #require(now["p0"]).maxX
            #expect(divider >= last - 0.01, "frame \(frames): the divider moved left (\(last) -> \(divider))")
            #expect(now["p0"]?.minX == start["p0"]?.minX && now["p1"]?.maxX == start["p1"]?.maxX, "frame \(frames): an outer edge moved")
            last = divider
            frames += 1
        }
        #expect(frames > 1, "the press did not spring")
        #expect(abs(last - (try #require(start["p0"]).maxX + rig.step)) <= 1, "the divider rests at \(last)")
    }

    /// A trade is one press: both widths go out under one layout transaction.
    @Test func aTradeSendsBothWidthsInOneTransaction() throws {
        let rig = Rig(Self.columns([0.5, 0.5]), focus: "p1")
        defer { rig.window.closeAfterTest() }
        #expect(rig.press("p1", .right))
        let sent = rig.ended.compactMap { intent -> (LayoutColumnID, Double, LayoutTransactionID)? in
            guard case let .setColumnWidth(column, _, width, transaction, .ended) = intent else { return nil }
            return (column, width, transaction)
        }
        #expect(sent.count == 2, "want the two columns' widths, got \(sent)")
        #expect(Set(sent.map(\.2)).count == 1, "the trade's widths went out in \(Set(sent.map(\.2)).count) transactions")
        #expect(Set(sent.map(\.0)) == ["c0", "c1"])
    }

    /// One scrolling column has no divider beside it: its right edge moves with the arrow (as before), up to the full
    /// strip.
    @Test func aSingleColumnMovesItsRightEdge() throws {
        let rig = Rig(Self.columns([0.5]), focus: "p0")
        defer { rig.window.closeAfterTest() }
        let before = try #require(try rig.shown()["p0"])
        #expect(rig.press("p0", .right))
        let wider = try #require(try rig.shown()["p0"])
        #expect(wider.minX == before.minX && abs(wider.maxX - before.maxX - rig.step) <= 1, "\(before) -> \(wider)")
        #expect(rig.press("p0", .left))
        let back = try #require(try rig.shown()["p0"])
        #expect(back.minX == before.minX && abs(back.maxX - before.maxX) <= 1, "\(wider) -> \(back)")
    }

    // MARK: Side docks

    /// A right dock's inner edge is its left edge: Right moves it right (the dock shrinks), Left moves it left.
    @Test(arguments: [LayoutDirection.right, .left])
    func aRightDocksInnerEdgeMovesWithTheArrow(direction: LayoutDirection) throws {
        let dock = LayoutColumn(id: "d", width: 0.3, root: .leaf("pd"), dock: DockColumn(edge: .right, mode: .docked))
        let rig = Rig([LayoutColumn(id: "c0", width: 1, root: .leaf("p0")), dock], focus: "pd")
        defer { rig.window.closeAfterTest() }
        let before = try #require(try rig.shown()["pd"])
        #expect(rig.press("pd", direction))
        let after = try #require(try rig.shown()["pd"])
        let moved = after.minX - before.minX
        #expect(direction == .right ? moved > 0 : moved < 0, "Right/Left moved the right dock's inner edge by \(moved)")
        #expect(abs(after.maxX - before.maxX) < 0.01, "the dock left its edge")
    }

    /// A left dock's inner edge is its right edge: Right grows the dock.
    @Test(arguments: [LayoutDirection.right, .left])
    func aLeftDocksInnerEdgeMovesWithTheArrow(direction: LayoutDirection) throws {
        let dock = LayoutColumn(id: "d", width: 0.3, root: .leaf("pd"), dock: DockColumn(edge: .left, mode: .docked))
        let rig = Rig([dock, LayoutColumn(id: "c0", width: 1, root: .leaf("p0"))], focus: "pd")
        defer { rig.window.closeAfterTest() }
        let before = try #require(try rig.shown()["pd"])
        #expect(rig.press("pd", direction))
        let after = try #require(try rig.shown()["pd"])
        let moved = after.maxX - before.maxX
        #expect(direction == .right ? moved > 0 : moved < 0, "Right/Left moved the left dock's inner edge by \(moved)")
    }
}

/// Review of #34123 (Codex): a press steps from what the screen shows, so neither outer edge of a trade moves by a
/// pixel, and a press that would change nothing on screen is refused (no model write).
struct KeyboardResizeShownStepTests {
    static let viewport = CGSize(width: 1153, height: 857)

    /// A column minimum with a fraction of a point: `ColumnStripGeometry.frames` shows a column below it at the
    /// minimum rounded up to a pixel.
    static var style: LayoutStyle {
        var style = LayoutStyle()
        style.minimumPaneContentSize = CGSize(width: 200.1, height: 64)
        return style
    }

    static func change(_ pane: LayoutPaneID, _ direction: LayoutDirection, _ layout: ScreenLayout, scale: CGFloat) -> PaneResize.Change? {
        let geometry = ScreenGeometry.compute(layout, viewport: viewport, style: style, scale: scale)
        return PaneResize.change(for: pane, direction: direction, in: layout, shown: ShownResizeRange(geometry: geometry, style: style, scale: scale))
    }

    /// c0 is stored below its minimum, so it shows widened to the minimum rounded up to a pixel. Right on p0 trades
    /// with c1: c0's left edge and c1's right edge stay to the pixel, and the divider moves one whole step.
    @Test(arguments: [CGFloat(1), 2])
    func aTradeFromAColumnShownAtItsMinimumMovesNoOuterEdge(scale: CGFloat) throws {
        let style = Self.style
        let minimum = LayoutColumn(id: "m", root: .leaf("m")).minimumSize(style: style).width
        let unit = Self.viewport.width - style.stripGap
        let below = ColumnStripGeometry.fraction(forPixelWidth: minimum - 10, viewportWidth: Self.viewport.width, gap: style.stripGap)
        let layout = ScreenLayout.columns([LayoutColumn(id: "c0", width: below, root: .leaf("p0")), LayoutColumn(id: "c1", width: 0.5, root: .leaf("p1"))])
        let before = ScreenGeometry.compute(layout, viewport: Self.viewport, style: style, scale: scale)
        let c0 = try #require(before.columns["c0"]), c1 = try #require(before.columns["c1"])
        try #require(c0.width > minimum - 10 + 1, "c0 is not shown widened to its minimum (\(c0.width))")
        guard case let .columnTrade(left, leftWidth, right, rightWidth)? = Self.change("p0", .right, layout, scale: scale) else {
            Issue.record("Right on p0 made no trade")
            return
        }
        let after = ScreenGeometry.compute(layout.settingWidth(leftWidth, for: left).settingWidth(rightWidth, for: right),
                                           viewport: Self.viewport, style: style, scale: scale)
        let c0After = try #require(after.columns["c0"]), c1After = try #require(after.columns["c1"])
        #expect(c0After.minX == c0.minX, "c0's left edge moved: \(c0.minX) -> \(c0After.minX)")
        #expect(c1After.maxX == c1.maxX, "c1's right edge moved: \(c1.maxX) -> \(c1After.maxX)")
        let step = (unit * CGFloat(PaneResize.step) * scale).rounded() / scale
        #expect(c0After.maxX - c0.maxX == step, "the divider's left side moved \(c0After.maxX - c0.maxX), want \(step)")
        #expect(c1After.minX - c1.minX == step, "the divider's right side moved \(c1After.minX - c1.minX), want \(step)")
        // Left on p0 would take c0 below the minimum it shows at: refused.
        #expect(Self.change("p0", .left, layout, scale: scale) == nil)
    }

    /// A side dock's width shows between its minimum and its share of the window (`DockStripGeometry.maxShare`). A
    /// right dock stored past that share shows at the share: Left (grow) is refused, and Right (shrink) is a whole step
    /// from the width it shows.
    @Test func aDockAtItsShareCapRefusesToGrowAndShrinksAWholeStep() throws {
        let style = LayoutStyle()
        let dock = LayoutColumn(id: "d", width: 0.9, root: .leaf("pd"), dock: DockColumn(edge: .right, mode: .docked))
        let layout = ScreenLayout.columns([LayoutColumn(id: "c0", width: 1, root: .leaf("p0")), dock])
        func change(_ direction: LayoutDirection) -> PaneResize.Change? {
            let geometry = ScreenGeometry.compute(layout, viewport: Self.viewport, style: style)
            return PaneResize.change(for: "pd", direction: direction, in: layout, shown: ShownResizeRange(geometry: geometry, style: style))
        }
        #expect(change(.left) == nil, "Left grew a dock shown at its share cap: the press changes the model and moves nothing")
        guard case let .columnWidth(id, width)? = change(.right) else {
            Issue.record("Right on a right dock made no change")
            return
        }
        let before = try #require(ScreenGeometry.compute(layout, viewport: Self.viewport, style: style).columns["d"])
        let after = try #require(ScreenGeometry.compute(layout.settingWidth(width, for: id), viewport: Self.viewport, style: style).columns["d"])
        let step = (Self.viewport.width - style.stripGap) * CGFloat(PaneResize.step)
        #expect(abs(after.minX - before.minX - step) <= 1, "the dock's inner edge moved \(after.minX - before.minX), want \(step)")
    }

    /// A screen whose only column is a dock shows it full width (`DockStripGeometry.docks`): no press moves it, so none
    /// changes its stored width.
    @Test(arguments: [LayoutDirection.left, .right])
    func aLoneDockRefusesThePress(direction: LayoutDirection) {
        let layout = ScreenLayout.columns([LayoutColumn(id: "d", width: 0.3, root: .leaf("pd"), dock: DockColumn(edge: .right, mode: .docked))])
        let change = Self.change("pd", direction, layout, scale: 2)
        #expect(change == nil, "\(direction) on a lone dock made \(String(describing: change)): it moves nothing")
    }
}

/// Undo Layout Change takes one press back in one step: the daemon keeps one undo entry per transaction
/// (`layout_undo_coalesces_every_target_in_one_resize_transaction`), so every value of one layout transaction (a
/// trade's two widths, an Option or Command drag's release) must go out under one daemon transaction. Each command
/// took a new number: one press was two undo steps.
@MainActor
@Suite(.closesItsWindows)
struct KeyboardResizeOneUndoStepTests {
    @Test func theValuesOfOneLayoutTransactionGoOutAsOneDaemonTransaction() throws {
        let shown = try PaneCloseControllerTests.Shown([ColumnSnapshot(id: 10, width: 0.5, layout: .leaf(1)),
                                                        ColumnSnapshot(id: 11, width: 0.5, layout: .leaf(2))])
        defer { shown.end() }
        let content = try #require(shown.content)
        let (left, right) = (LayoutPaneID(try shown.key(1)), LayoutPaneID(try shown.key(2)))
        let press = LayoutTransactionID.make()
        let first = content.nextGestureTransaction
        content.handle(.setColumnWidth(LayoutColumnID("column:10"), anyPane: left, width: 0.55, transaction: press, phase: .ended))
        content.handle(.setColumnWidth(LayoutColumnID("column:11"), anyPane: right, width: 0.45, transaction: press, phase: .ended))
        #expect(content.nextGestureTransaction == first + 1, "one press took \(content.nextGestureTransaction - first) daemon transactions")
        // The next press is its own undo step.
        content.handle(.setColumnWidth(LayoutColumnID("column:10"), anyPane: left, width: 0.6, transaction: .make(), phase: .ended))
        #expect(content.nextGestureTransaction == first + 2)
    }
}
