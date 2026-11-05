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
