import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// Command on a column edge gives every scrolling column the dragged column's width (resize-modifiers.md, Finder's
/// all-columns drag). The dragged edge must still follow the pointer, as in every other mode: the person drags that
/// edge (FRAME OWNER S2B rule D: the pointer alone moves the line, and a still pointer holds it). The columns before the
/// dragged one take the new width too and move its left edge; the camera keeps the dragged column in place for that
/// (`ScreenDividers.dragAnchorColumn`) only where the strip leaves it room.
/// - A strip that fits its viewport leaves the camera none. On feat (step a73b39aa5294dcc2a520401b) one frame after a
///   30 pt move of c1's edge the edge showed 31 pt from its start, then slid on under the still pointer, 33, 36, 39 ...
///   56 pt by frame 11 (the camera's value took the anchor's shift, its target was clamped back, and it sprang back).
/// - A strip that scrolls leaves it room, but the drag measured the pointer with the camera the anchor had already
///   moved, so each move after the first added the camera's last shift to the width.
/// Found in the review of #35775; the switch OFF and feat show the same.
@MainActor
@Suite(.closesItsWindows)
struct CommandColumnEdgeFollowsPointerTests {
    typealias Screen = DividerModifierDragTests.Screen

    /// Where `pane`'s right edge shows: its host's frame, as the screen places it (camera included).
    func edge(_ screen: Screen, _ pane: PaneID) throws -> CGFloat {
        try #require(screen.root.context.hosts[pane], "no host for \(pane)").frame.maxX
    }

    /// Display frames until nothing moves (at most 2 s), each one checked: c1's right edge (p3's) shows `want` points
    /// from `before`, within a point.
    func expectEdgeHolds(_ screen: Screen, at want: CGFloat, from before: CGFloat, _ label: String) throws -> [String] {
        var misses: [String] = [], frames = 0, moving = true
        while moving, frames < 240 {
            let moved = try edge(screen, "p3") - before
            if abs(moved - want) >= 1 { misses.append("\(label) frame \(frames): c1's right edge moved \(moved) pt, the pointer \(want) pt") }
            frames += 1
            moving = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded()
        }
        return misses
    }

    @Test(arguments: [CGFloat(30), -30])
    func commandDraggingTheSecondColumnsEdgeInAStripThatFitsMovesItWithThePointer(_ dx: CGFloat) throws {
        // Three columns at 0.3 of the strip: the strip fits, and it still fits with every column 30 pt wider.
        let screen = Screen(DividerModifierDragTests.threeColumns([0.3, 0.3, 0.3]))
        defer { screen.window.closeAfterTest() }
        try #require(screen.screen.geometry.maxOffset < 0.5, "the strip scrolls: \(screen.screen.geometry.maxOffset) pt of room")
        // c1 is one pane, p3: its right edge is the column's.
        let before = try edge(screen, "p3")

        let (view, from) = try screen.press(.columnEdge("c1"), flags: .command)
        screen.move(view, from: from, by: dx, flags: .command)
        // Command's mode: every column takes the dragged one's width.
        let c1 = try #require(screen.width("c1"))
        #expect(screen.width("c0") == c1 && screen.width("c2") == c1, "Command did not give every column c1's width")
        // The pointer holds still: in every frame until the motion stops, the edge shows where the pointer put it.
        let misses = try expectEdgeHolds(screen, at: dx, from: before, "still")
        #expect(misses.isEmpty, "\(misses.count) frames off (first 6):\n\(misses.prefix(6).joined(separator: "\n"))")
        screen.release(view, at: CGPoint(x: from.x + dx, y: from.y), flags: .command)
    }

    @Test func commandDraggingWhileTheCameraSpringsMeasuresThePointerWhereItShows() throws {
        // Codex review of 667ef1ebb0c: the camera shows 0 pt on its way to 100 pt (a reveal in flight) when c0's edge is
        // dragged 30 pt right with Command. c0 has no column before it, so no anchor shift: it grows by the pointer's
        // 30 pt, as a plain drag does, not by the camera's 100 pt still to go as well.
        let screen = Screen(DividerModifierDragTests.threeColumns([0.45, 0.45, 0.45]))
        defer { screen.window.closeAfterTest() }
        let view = screen.screen
        try #require(view.geometry.maxOffset > 150, "the strip has \(view.geometry.maxOffset) pt of room")
        let start = try #require(view.geometry.columns["c0"]).width
        // The camera at rest at 0, its target 100 pt on: a spring the drag's frame steps.
        view.scroll.target = 100
        let (handle, from) = try screen.press(.columnEdge("c0"), flags: .command)
        handle.mouseDragged(with: NSEvent.mouseEvent(with: .leftMouseDragged, location: CGPoint(x: from.x + 30, y: from.y), modifierFlags: .command,
                                                     timestamp: 0, windowNumber: screen.window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: 1)!)
        _ = screen.root.advanceFrame(1.0 / 120)
        let width = try #require(view.geometry.columns["c0"]).width
        #expect(abs(width - (start + 30)) < 1, "c0 is \(width - start) pt wider for the pointer's 30 pt")
        screen.release(handle, at: CGPoint(x: from.x + 30, y: from.y), flags: .command)
    }

    @Test func commandShrinkingTheSecondColumnAtTheStripsEndHoldsTheEdgeWithoutASlide() throws {
        // Codex review of 25f458ccd4c: the camera at the strip's end, c1's edge Command-dragged 30 pt left. No width rests it
        // under the pointer there (a shrink moves it right at this end); the width the drag took before (the plain extent)
        // made the camera spring back and slid the edge about 60 pt right under the still pointer. It holds at its limit.
        let screen = Screen(DividerModifierDragTests.threeColumns([0.45, 0.45, 0.45]))
        defer { screen.window.closeAfterTest() }
        let view = screen.screen
        let end = view.geometry.maxOffset
        try #require(end > 200, "the strip has \(end) pt of room")
        (view.scroll.value, view.scroll.target) = (end, end)
        view.applyPresentation(force: true)
        screen.root.layoutSubtreeIfNeeded()
        let before = try edge(screen, "p3")
        try #require(before > 40 && before < screen.root.bounds.maxX - 40, "c1's edge is off screen at \(before) pt")

        let (handle, from) = try screen.press(.columnEdge("c1"), flags: .command)
        screen.move(handle, from: from, by: -30, flags: .command)
        var moved: [CGFloat] = [], frames = 0, moving = true
        while moving, frames < 240 {
            moved.append(try edge(screen, "p3") - before)
            frames += 1
            moving = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded()
        }
        // It never moves away from the pointer (right of its start), and nothing moves it under the still pointer.
        #expect(moved.allSatisfy { $0 <= 1 && $0 >= -31 }, "the edge moved \(moved.prefix(8)) pt for the pointer's -30 pt")
        #expect((moved.max() ?? 0) - (moved.min() ?? 0) <= 1, "the edge slid from \(moved.min() ?? 0) to \(moved.max() ?? 0) pt under the still pointer")
        screen.release(handle, at: CGPoint(x: from.x - 30, y: from.y), flags: .command)
    }

    @Test func commandDraggingTheSecondColumnsEdgeInAStripThatScrollsFollowsThePointerOverSeveralMoves() throws {
        // Three columns at 0.45 of the strip: it scrolls, the camera rests at its start with room to move.
        let screen = Screen(DividerModifierDragTests.threeColumns([0.45, 0.45, 0.45]))
        defer { screen.window.closeAfterTest() }
        try #require(screen.screen.geometry.maxOffset > 200, "the strip has \(screen.screen.geometry.maxOffset) pt of room")
        let before = try edge(screen, "p3")
        try #require(before < screen.root.bounds.maxX - 40, "c1's edge is off screen at \(before) pt")

        let (view, from) = try screen.press(.columnEdge("c1"), flags: .command)
        var misses: [String] = []
        // Two moves, the pointer still after each: 15 pt, then 30 pt from the press.
        for dx in [CGFloat(15), 30] {
            screen.move(view, from: from, by: dx, flags: .command)
            misses += try expectEdgeHolds(screen, at: dx, from: before, "after \(dx) pt")
        }
        #expect(misses.isEmpty, "\(misses.count) frames off (first 6):\n\(misses.prefix(6).joined(separator: "\n"))")
        screen.release(view, at: CGPoint(x: from.x + 30, y: from.y), flags: .command)
    }
}
