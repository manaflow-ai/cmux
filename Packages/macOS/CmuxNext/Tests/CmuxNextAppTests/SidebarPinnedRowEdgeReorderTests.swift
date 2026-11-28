import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Pinned workspace rows reorder by the rule the unpinned rows use (Lawrence 2026-11-15: "algorithm for rearranging
/// pinned workspaces when i drag them around is different for unpinned workspaces; unpinned reordering feels
/// better"): a dragged row goes past its neighbour when its leading edge passes that neighbour's middle
/// (`SidebarDragGeometry.edgeY`, as `SidebarRowEdgeReorderDocDragTests` shows for the list's rows). The pinned rows
/// used the card's centre against the rows as laid out without the open gap, so a row dragged down passed its
/// second neighbour as soon as it touched it, and a row dragged up had to reach its neighbour's top.
///
/// The real list with the Pinned block's three rows (`SidebarHomePinnedDragHarness`), pressed and dragged with
/// mouse events; the drop is the one move the document is sent. The rows are pinned links: a pinned workspace never
/// drags (`aPinnedWorkspaceRowDoesNotLift`).
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarPinnedRowEdgeReorderTests {
    typealias Harness = SidebarHomePinnedDragHarness

    init() { Motion.reduceMotionOverride = true }

    /// Pinned row `index`'s frame in the list (y grows down).
    static func frame(_ h: Harness, _ index: Int) throws -> CGRect {
        let view = try h.item(Harness.pins[index].id)
        return h.list.convert(view.bounds, from: view)
    }

    /// Presses pinned row `index` at its centre, moves the pointer `dy` points down the list (negative: up) in
    /// 1 pt steps, holds it there for a few more moves and lets go.
    static func drag(_ h: Harness, pin index: Int, by dy: CGFloat) throws {
        let view = try h.item(Harness.pins[index].id)
        let start = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        view.mouseDown(with: try h.mouse(.leftMouseDown, at: start))
        let steps = max(2, Int(abs(dy).rounded(.up)))
        for step in Array(1...steps) + [steps, steps, steps] {
            let y = start.y - dy * CGFloat(step) / CGFloat(steps) // the window's y grows up
            view.mouseDragged(with: try h.mouse(.leftMouseDragged, at: NSPoint(x: start.x, y: y)))
        }
        #expect(h.list.drag != nil, "the pinned row did not lift")
        view.mouseUp(with: try h.mouse(.leftMouseUp, at: NSPoint(x: start.x, y: start.y - dy)))
        h.finishFlights()
    }

    /// The place among the pinned rows (without pinned row `moved`) the one drop sent puts it; nil when no drop,
    /// more than one, or a drop out of Pinned was sent.
    static func place(_ h: Harness, moved: Int) -> Int? {
        guard h.drops.count == 1, let (items, target) = h.drops.first, items == [Harness.pins[moved].id.rawValue],
              target.section == SidebarDocStore.pinnedSection else { return nil }
        let rest = Harness.pins.map(\.id.rawValue).filter { $0 != items[0] }
        if let before = target.before { return rest.firstIndex(of: before) }
        if let after = target.after { return rest.firstIndex(of: after).map { $0 + 1 } }
        return target.index
    }

    static func sent(_ h: Harness) -> String { "\(h.drops.map { "\($0.0) -> \($0.1)" })" }

    /// A pinned workspace never drags, as in classic cmux (Lucas 2026-11-26: "the pinned workspaces should also not be
    /// movable, even if its moving to unpin"): a press and a long drag lift nothing and send no move.
    @Test func aPinnedWorkspaceRowDoesNotLift() throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness()
        defer { h.close() }
        let view = try h.item(Harness.pins[0].id)
        let start = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        view.mouseDown(with: try h.mouse(.leftMouseDown, at: start))
        for down in stride(from: CGFloat(4), through: 120, by: 4) {
            view.mouseDragged(with: try h.mouse(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - down)))
        }
        #expect(h.list.drag == nil, "the pinned workspace lifted")
        view.mouseUp(with: try h.mouse(.leftMouseUp, at: NSPoint(x: start.x, y: start.y - 120)))
        h.finishFlights()
        #expect(h.drops.isEmpty, "a pinned workspace drag sent a move: \(Self.sent(h))")
    }

    /// The first pinned row dragged down until its bottom is 2 pt short of the third row's middle: it passed the
    /// second row only (the third has not made way).
    @Test func aPinnedRowDraggedDownStaysBeforeARowItsBottomHasNotHalfCovered() throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness(pinsAreLinks: true)
        defer { h.close() }
        let first = try Self.frame(h, 0), third = try Self.frame(h, 2)
        try Self.drag(h, pin: 0, by: third.midY - 2 - first.maxY)
        #expect(Self.place(h, moved: 0) == 1, "the row is not between the second and third pinned rows: \(Self.sent(h))")
        h.expectEveryRowAtRest("after a pinned row dragged down past one row")
    }

    /// 4 pt further, its bottom is past the third row's middle: it goes after the third row.
    @Test func aPinnedRowDraggedDownPassesARowWhenItsBottomPassesThatRowsMiddle() throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness(pinsAreLinks: true)
        defer { h.close() }
        let first = try Self.frame(h, 0), third = try Self.frame(h, 2)
        try Self.drag(h, pin: 0, by: third.midY + 2 - first.maxY)
        #expect(Self.place(h, moved: 0) == 2, "the row is not after the third pinned row: \(Self.sent(h))")
        h.expectEveryRowAtRest("after a pinned row dragged down past two rows")
    }

    /// The first list row's frame in the list (the row under the Pinned block).
    static func firstListRow(_ h: Harness) throws -> CGRect {
        let row = try #require(h.list.displayed.row(for: .workspace(Harness.loose[0])))
        return CGRect(x: 0, y: row.y, width: h.list.bounds.width, height: row.height)
    }

    /// In the last pinned place and further down, its bottom 2 pt short of the first list row's middle: the row
    /// stays pinned (the list rows are drawn where they were: the gap holds the dragged row's place in the block).
    @Test func aPinnedRowStaysPinnedWhileItsBottomIsShortOfTheFirstListRowsMiddle() throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness(pinsAreLinks: true)
        defer { h.close() }
        let first = try Self.frame(h, 0), below = try Self.firstListRow(h)
        try Self.drag(h, pin: 0, by: below.midY - 2 - first.maxY)
        #expect(Self.place(h, moved: 0) == 2, "the row is not the last pinned row: \(Self.sent(h))")
        h.expectEveryRowAtRest("after a pinned row held over the first list row's top half")
    }

    /// 5 pt further, its bottom is past the first list row's middle: it leaves Pinned for the list.
    @Test func aPinnedRowLeavesPinnedWhenItsBottomPassesTheFirstListRowsMiddle() throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness(pinsAreLinks: true)
        defer { h.close() }
        let first = try Self.frame(h, 0), below = try Self.firstListRow(h)
        try Self.drag(h, pin: 0, by: below.midY + 3 - first.maxY)
        #expect(h.drops.count == 1 && h.drops.first?.1.section == Harness.machineSection, "the row did not go to the list: \(Self.sent(h))")
        h.expectEveryRowAtRest("after a pinned row dragged into the list")
    }

    /// The third pinned row dragged up until its top is 2 pt past the second row's middle: it goes before the second row.
    @Test func aPinnedRowDraggedUpPassesARowWhenItsTopPassesThatRowsMiddle() throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness(pinsAreLinks: true)
        defer { h.close() }
        let second = try Self.frame(h, 1), third = try Self.frame(h, 2)
        try Self.drag(h, pin: 2, by: second.midY - 2 - third.minY)
        #expect(Self.place(h, moved: 2) == 1, "the row is not between the first and second pinned rows: \(Self.sent(h))")
        h.expectEveryRowAtRest("after a pinned row dragged up past one row")
    }

    /// 4 pt less, its top is short of the second row's middle: it stays where it was, and no move is sent.
    @Test func aPinnedRowDraggedUpStaysWhileItsTopIsShortOfTheMiddleAbove() throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness(pinsAreLinks: true)
        defer { h.close() }
        let second = try Self.frame(h, 1), third = try Self.frame(h, 2)
        try Self.drag(h, pin: 2, by: second.midY + 2 - third.minY)
        #expect(h.drops.isEmpty, "a row that passed no row was moved: \(Self.sent(h))")
        h.expectEveryRowAtRest("after a pinned row dragged up short of the row above")
    }
}
