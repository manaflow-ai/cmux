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
    /// refused as at a minimum width, and nothing moves.
    @Test func aDividerAtTheWindowsEdgeDoesNotMoveOutOfIt() throws {
        let rig = Rig(Self.columns([0.5, 0.5, 0.5]), focus: "p1")
        defer { rig.window.closeAfterTest() }
        let before = try rig.shown()
        #expect(!rig.press("p1", .right), "the press moved the divider out of the window, or scrolled the strip")
        #expect(try rig.shown() == before)
        #expect(rig.ended.isEmpty)
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
