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
@Suite(.closesItsWindows)
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

    /// Claude review of #34123: on a strip of an odd number of device pixels, 0.5 of it is an exact half pixel, and the
    /// last column is cut back to the strip's end when the columns fill it (`ColumnStripGeometry.frames`): a trade made of
    /// whole pixels on each stored width rounded the two columns different ways or left the cut, so a press moved the
    /// last column's right edge by a pixel; the daemon keeps a width as `f32`, and its echo moved it again. Every press of
    /// a walk across the strip, at 1x and 2x, moves only the divider, by whole pixels toward the arrow, before and after
    /// the echo (or is refused).
    @Test(arguments: [(CGFloat(1201), CGFloat(1), true), (1963, 1, true), (1453.5, 2, true), (1201, 1, false), (1453.5, 2, false)])
    func everyPressOnAnOddPixelStripMovesOnlyTheDivider(width: CGFloat, scale: CGFloat, atEnd: Bool) throws {
        // The app's default strip: edge to edge, no gap (`Metrics.stripColumnGap`).
        var style = LayoutStyle()
        style.columnGap = 0
        try #require(style.stripGap == 0)
        let viewport = CGSize(width: width, height: 800)
        var layout = ScreenLayout.columns([LayoutColumn(id: "c0", width: 0.5, root: .leaf("p0")),
                                           LayoutColumn(id: "c1", width: 0.5, root: .leaf("p1")),
                                           LayoutColumn(id: "c2", width: 0.5, root: .leaf("p2"))])
        /// The daemon's echo of a width: the `f32` it keeps.
        func echoed(_ layout: ScreenLayout) -> ScreenLayout {
            layout.columns.reduce(layout) { $0.settingWidth(Double(Float($1.width)), for: $1.id) }
        }
        // The camera at the strip's start (c0 and c1 show) or at its end (c1 and c2 show), where the press keeps it.
        let presses: [(LayoutPaneID, LayoutDirection)] = atEnd
            ? [("p2", .right), ("p2", .left), ("p2", .left), ("p1", .right), ("p0", .right), ("p2", .right)]
            : [("p0", .right), ("p1", .left), ("p0", .left), ("p0", .right), ("p1", .right), ("p0", .left)]
        let offset = atEnd ? ScreenGeometry.compute(layout, viewport: viewport, style: style, scale: scale).maxOffset : 0
        var moved = 0
        for (pane, direction) in presses {
            let before = ScreenGeometry.compute(layout, viewport: viewport, style: style, scale: scale)
            let shown = ShownResizeRange(geometry: before, style: style, scale: scale, stripOffset: offset)
            guard case let .columnTrade(left, leftWidth, right, rightWidth)? = PaneResize.change(for: pane, direction: direction, in: layout,
                                                                                                    shown: shown) else { continue }
            let next = layout.settingWidth(leftWidth, for: left).settingWidth(rightWidth, for: right)
            let full = ((viewport.width - style.stripGap) * CGFloat(PaneResize.step) * scale).rounded() / scale
            for (when, after) in [("at the press", next), ("after the echo", echoed(next))] {
                let placed = ScreenGeometry.compute(after, viewport: viewport, style: style, scale: scale)
                let l0 = try #require(before.columns[left]), r0 = try #require(before.columns[right])
                let l1 = try #require(placed.columns[left]), r1 = try #require(placed.columns[right])
                let step = l1.maxX - l0.maxX
                #expect(direction == .right ? step > 0 : step < 0, "\(pane) \(direction) \(when): the divider moved \(step)")
                #expect(r1.minX - r0.minX == step, "\(pane) \(direction) \(when): the divider's sides moved \(step) and \(r1.minX - r0.minX)")
                #expect(l1.minX == l0.minX && r1.maxX == r0.maxX,
                        "\(pane) \(direction) \(when): an outer edge moved (\(l0.minX) -> \(l1.minX), \(r0.maxX) -> \(r1.maxX))")
                for (id, frame) in before.columns where id != left && id != right {
                    #expect(placed.columns[id] == frame, "\(pane) \(direction) \(when): column \(id) moved")
                }
                #expect(abs(step) == full, "\(pane) \(direction) \(when): a step of \(step), want the whole step \(full)")
            }
            layout = echoed(next)
            moved += 1
        }
        // None of these presses is at a limit: each one moves the divider.
        #expect(moved == presses.count, "only \(moved) of \(presses.count) presses moved a divider")
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

/// Claude review of #34123: a trade sends two widths, one daemon command each, under one transaction. The first
/// command's reply settled the whole transaction, so a daemon snapshot that came before the second command's event
/// (the store applies events once per display frame) dropped the second width's override, and for a frame that column
/// showed its old width and every column after it jumped. The transaction settles when its last value is answered.
@MainActor
@Suite(.closesItsWindows)
struct KeyboardResizeTradeSettleTests {
    @Test func aTradeSettlesWhenItsLastWidthIsAnswered() throws {
        let columns = [LayoutColumn(id: "c0", width: 0.5, root: .leaf("p0")), LayoutColumn(id: "c1", width: 0.5, root: .leaf("p1"))]
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: "p0")
        model.intentHandler = { _ in } // the app sends each width as its own command, and settles it at its reply
        func width(_ column: LayoutColumnID) -> Double? { model.screens.first?.layout.columns.first { $0.id == column }?.width }
        func daemon(_ c0: Double, _ c1: Double) -> [LayoutScreen] {
            [LayoutScreen(id: "s", name: "s", layout: .columns([LayoutColumn(id: "c0", width: c0, root: .leaf("p0")),
                                                                 LayoutColumn(id: "c1", width: c1, root: .leaf("p1"))]))]
        }
        let press = LayoutTransactionID.make()
        model.setColumnWidth("c0", width: 0.55, transaction: press, phase: .ended)
        model.setColumnWidth("c1", width: 0.45, transaction: press, phase: .ended)
        // c0's reply, then a daemon snapshot with c0's change only (c1's event comes in the next frame).
        model.settleTransaction(press)
        model.apply(screens: daemon(0.55, 0.5))
        #expect(width("c0") == 0.55)
        #expect(width("c1") == 0.45, "the first reply let a snapshot without the second width show c1 at \(String(describing: width("c1")))")
        // c1's reply and its event: the daemon's widths, nothing held over them.
        model.settleTransaction(press)
        model.apply(screens: daemon(0.55, 0.45))
        model.apply(screens: daemon(0.6, 0.4))
        #expect(width("c0") == 0.6 && width("c1") == 0.4, "a settled trade still held its widths over the daemon's")
    }
}

/// Claude review of #34123: a press whose widths the app refused at once (a pane with no daemon handle yet, such as a
/// column still being made) changed nothing, so its own sync never ran, and the column it kept in place stayed for the
/// next sync, which then skipped its reveal: the column focused next did not scroll into view.
@MainActor
@Suite(.closesItsWindows)
struct KeyboardResizeRefusedPressTests {
    @Test func aRefusedPressLeavesTheNextRevealAlone() throws {
        let rig = KeyboardResizeArrowDirectionTests.Rig(KeyboardResizeArrowDirectionTests.columns([0.5, 0.5, 0.5]), focus: "p0")
        defer { rig.window.closeAfterTest() }
        rig.model.intentHandler = { [model = rig.model] intent in
            if case let .setColumnWidth(_, _, _, transaction, .ended) = intent { model.rejectTransaction(transaction) }
        }
        let screen = try rig.screen
        #expect(screen.scroll.target == 0)
        _ = rig.press("p0", .right)
        // A key focus on the column past the window's edge scrolls it into view.
        rig.model.focus("p2", source: .keyboard)
        rig.root.syncWithModel()
        #expect(screen.scroll.target > 0, "the focus after a refused press did not reveal p2")
    }
}

/// Codex re-review of #34123 (FIX at 7dc25a2a2dab): a trade is one change, all or nothing, on the screen and on the wire.
/// - The app refused the trade's first width at once (no handle for its pane), which rolled the press back, and then
///   the press set and sent the second width anyway: only one column changed, so every column after the pair moved.
/// - A reply that came in the turn of the first width's command (a handler that settles at once) settled the trade
///   before its second width was counted, so a daemon snapshot before the second width's event showed the first column
///   at its old width.
/// - A trade beside a column the daemon has not made yet (a stand-in, `ProvisionalPane`) sent the other column's width,
///   which the daemon applied, and the stand-in's, which it refused: half a trade at the daemon. The press is refused
///   at once instead, before anything moves, as other pane verbs on a stand-in are.
@MainActor
@Suite(.closesItsWindows)
struct KeyboardResizeTradeAtomicTests {
    @Test func aTradeWhoseFirstWidthIsRefusedShowsAndSendsNeither() throws {
        let rig = KeyboardResizeArrowDirectionTests.Rig(KeyboardResizeArrowDirectionTests.columns([0.5, 0.5]), focus: "p1")
        defer { rig.window.closeAfterTest() }
        var sent: [LayoutColumnID] = []
        rig.model.intentHandler = { [model = rig.model] intent in
            guard case let .setColumnWidth(column, _, _, transaction, .ended) = intent else { return }
            // c0's pane has no handle: the app refuses its width at once.
            if column == "c0" { model.rejectTransaction(transaction) } else { sent.append(column) }
        }
        _ = rig.press("p1", .right)
        #expect(sent.isEmpty, "a trade refused for c0 still sent \(sent)")
        let widths = rig.model.screens[0].layout.columns.map(\.width)
        #expect(widths == [0.5, 0.5], "a trade refused for c0 shows widths \(widths)")
    }

    @Test func aReplyInTheFirstWidthsTurnDoesNotSettleTheTrade() throws {
        let rig = KeyboardResizeArrowDirectionTests.Rig(KeyboardResizeArrowDirectionTests.columns([0.5, 0.5]), focus: "p1")
        defer { rig.window.closeAfterTest() }
        rig.model.intentHandler = { [model = rig.model] intent in
            // c0's command is answered in its own turn; c1's reply comes later.
            if case .setColumnWidth("c0", _, _, let transaction, .ended) = intent { model.settleTransaction(transaction) }
        }
        #expect(rig.press("p1", .right))
        let trade = rig.model.screens[0].layout.columns.map(\.width)
        try #require(trade[0] > 0.5 && trade[1] < 0.5, "the press made no trade: \(trade)")
        // A daemon snapshot from before either event.
        rig.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(KeyboardResizeArrowDirectionTests.columns([0.5, 0.5])))])
        #expect(rig.model.screens[0].layout.columns.map(\.width) == trade, "the snapshot undid half the trade before its second reply")
    }

    /// Codex review 3 of #34123: a handler that answers the last width at once and applies the daemon's snapshot in that
    /// turn (a synchronous source, such as the layout demo's) removes the trade's overrides because it succeeded; the press
    /// read that as a refusal and said nothing moved.
    @Test func aTradeAnsweredAndAppliedInItsLastWidthsTurnIsAPress() throws {
        let rig = KeyboardResizeArrowDirectionTests.Rig(KeyboardResizeArrowDirectionTests.columns([0.5, 0.5]), focus: "p1")
        defer { rig.window.closeAfterTest() }
        var widths: [LayoutColumnID: Double] = [:]
        rig.model.intentHandler = { [model = rig.model] intent in
            guard case let .setColumnWidth(column, _, width, transaction, .ended) = intent else { return }
            widths[column] = width
            model.settleTransaction(transaction)
            guard widths.count == 2 else { return }
            let columns = KeyboardResizeArrowDirectionTests.columns([widths["c0"] ?? 0.5, widths["c1"] ?? 0.5])
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))])
        }
        #expect(rig.press("p1", .right), "a trade the daemon applied in its turn read as refused")
        let shown = rig.model.screens[0].layout.columns.map(\.width)
        #expect(shown[0] > 0.5 && shown[1] < 0.5, "the applied trade does not show: \(shown)")
    }

    @Test func aTradeBesideAColumnTheDaemonHasNotMadeIsRefusedAndSendsNothing() throws {
        // c11's pane is a stand-in: its handle is in the range no daemon pane has (`ProvisionalPane`, from 1 << 62).
        let standIn: UInt64 = (1 << 62) + 7
        let screen = ScreenSnapshot(id: 1, layout: .leaf(DaemonPaneID(rawValue: 1)),
                                    columns: [ColumnSnapshot(id: 10, width: 0.5, layout: .leaf(DaemonPaneID(rawValue: 1))),
                                              ColumnSnapshot(id: 11, width: 0.5, layout: .leaf(DaemonPaneID(rawValue: standIn)))],
                                    panes: [PaneSnapshot(id: DaemonPaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")]),
                                            PaneSnapshot(id: DaemonPaneID(rawValue: standIn), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~")])])
        let shown = try PaneCloseControllerTests.Shown(tree: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])]))
        defer { shown.end() }
        let content = try #require(shown.content)
        let pane = LayoutPaneID(try shown.key(1))
        try #require(content.layoutModel.screens.first?.layout.columns.count == 2, "the stand-in column does not show")
        let first = content.gestureTransactions.latest
        let before = content.layoutModel.screens.first?.layout.columns.map(\.width)
        #expect(!PaneResize.press(pane, .right, model: content.layoutModel, view: content.layoutView),
                "a trade with a column the daemon has not made went ahead")
        #expect(content.gestureTransactions.latest == first, "the refused trade sent \(content.gestureTransactions.latest - first) transactions")
        #expect(content.layoutModel.screens.first?.layout.columns.map(\.width) == before)
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
        let first = content.gestureTransactions.latest
        content.handle(.setColumnWidth(LayoutColumnID("column:10"), anyPane: left, width: 0.55, transaction: press, phase: .ended))
        content.handle(.setColumnWidth(LayoutColumnID("column:11"), anyPane: right, width: 0.45, transaction: press, phase: .ended))
        #expect(content.gestureTransactions.latest == first + 1, "one press took \(content.gestureTransactions.latest - first) daemon transactions")
        // The next press is its own undo step.
        content.handle(.setColumnWidth(LayoutColumnID("column:10"), anyPane: left, width: 0.6, transaction: .make(), phase: .ended))
        #expect(content.gestureTransactions.latest == first + 2)
    }
}
