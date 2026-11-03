import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// RESIZE KEYS (feat-5851715 films, lead 2026-11-03 03:3xZ, Lawrence: "resizing columns and splits is still not very
/// good"): a slow divider drag that starts on a snap (an equal split, a half, a third) did not move for the first 8 pt
/// of the pointer (`DividerDragState.snapDistance`), then jumped 8.5 pt to it: 91-99 ms of a still divider at 120 Hz,
/// then a lurch. The snap the drag starts on must not hold it; a snap the divider comes back to still does.
@MainActor
@Suite(.closesItsWindows)
struct DividerDragStartSnapTests {
    typealias Screen = DividerSnapTests.Screen

    /// Presses `split`'s divider and moves the pointer by each of `offsets` (points along x, from the press), then
    /// releases at the last one.
    private func drag(_ screen: Screen, _ split: SplitID, offsets: [CGFloat], snapKey: Bool = false) throws {
        let view = try #require(screen.screen)
        let divider = try #require(view.geometry.dividers.first { $0.id == split })
        let handle = try #require(view.dividerViews[.split(split)])
        let start = view.convert(CGPoint(x: divider.frame.midX + view.stripShift, y: divider.frame.midY), to: nil)
        let flags: NSEvent.ModifierFlags = snapKey ? [.shift] : []
        func event(_ type: NSEvent.EventType, _ dx: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: start.x + dx, y: start.y), modifierFlags: flags, timestamp: 0,
                               windowNumber: screen.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        handle.mouseDown(with: event(.leftMouseDown, 0))
        for dx in offsets { handle.mouseDragged(with: event(.leftMouseDragged, dx)) }
        handle.mouseUp(with: event(.leftMouseUp, offsets.last ?? 0))
    }

    private func available(_ screen: Screen, _ split: SplitID) throws -> CGFloat {
        let view = try #require(screen.screen)
        let divider = try #require(view.geometry.dividers.first { $0.id == split })
        return divider.container.width - view.context.style.dividerThickness
    }

    @Test(arguments: [CGFloat(1), 3, 6, -3])
    func aDragThatStartsOnASnapFollowsThePointerFromItsFirstPoint(_ dx: CGFloat) throws {
        let screen = Screen(.split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))
        defer { screen.window.closeAfterTest() }
        let room = try available(screen, "x")
        try drag(screen, "x", offsets: [dx / 2, dx])
        let ratio = try #require(screen.ratio("x"))
        // The divider is where the pointer took it, within a pixel; held at the half it moved nothing.
        #expect(abs((ratio - 0.5) * Double(room) - Double(dx)) <= 1, "a drag of \(dx) pt from the half left the divider \((ratio - 0.5) * Double(room)) pt away")
    }

    @Test func aDividerThatLeftItsStartSnapSnapsBackToIt() throws {
        let screen = Screen(.split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))
        defer { screen.window.closeAfterTest() }
        // Out past the snap's reach, then back within it: the half holds again.
        try drag(screen, "x", offsets: [20, 40, 4])
        #expect(screen.ratio("x") == 0.5)
    }

    @Test func aDragThatStartsOffASnapStillSnapsOntoOne() throws {
        let screen = Screen(.split("x", axis: .horizontal, ratio: 0.45, a: .leaf("p1"), b: .leaf("p2")))
        defer { screen.window.closeAfterTest() }
        let room = try available(screen, "x")
        // From 0.45 to 4 pt short of the half.
        try drag(screen, "x", offsets: [room * 0.05 - 4])
        #expect(screen.ratio("x") == 0.5)
    }

    @Test func shiftKeepsTheSnapTheDragStartsOn() throws {
        let screen = Screen(.split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))
        defer { screen.window.closeAfterTest() }
        // Shift snaps from any distance: the nearest snap to a 20 pt move from the half is still the half.
        try drag(screen, "x", offsets: [10, 20], snapKey: true)
        #expect(screen.ratio("x") == 0.5)
    }
}
