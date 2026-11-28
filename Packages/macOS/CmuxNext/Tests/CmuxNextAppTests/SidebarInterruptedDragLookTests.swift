import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-30 ("i tried to drag home around and now it's stuck in this state"): rows in the Pinned block kept
/// a pressed or hover fill after the gesture ended elsewhere. A press or drag of a pinned row that is interrupted (no
/// release reaches it) ends with every row at rest: no lifted card, no hidden source row, no pressed or hover fill,
/// no drop sent. Each interruption goes through the list's one gesture end (`endPointerGesture`).
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarInterruptedDragLookTests {
    typealias Harness = SidebarHomePinnedDragHarness

    init() { Motion.reduceMotionOverride = true }

    /// Presses the first pinned row and, with `drags`, drags it 40 pt down (the drag is held).
    private func press(_ h: Harness, drags: Bool) throws -> SidebarItemRowView {
        let pin = try h.item(Harness.pins[0].id)
        pin.mouseDown(with: try h.event(.leftMouseDown, on: pin))
        guard drags else { return pin }
        for down: CGFloat in [10, 25, 40] { pin.mouseDragged(with: try h.event(.leftMouseDragged, on: pin, down: down)) }
        #expect(h.list.drag != nil, "the fixture's pinned drag did not start")
        return pin
    }

    @Test(arguments: [false, true])
    func theWindowResigningKeyWithTheButtonUpEndsIt(_ drags: Bool) throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness()
        defer { h.close() }
        _ = try press(h, drags: drags)
        h.list.pointerWindowLostKey() // what the list's `NSWindow.didResignKeyNotification` observer runs
        h.finishFlights()
        #expect(h.drops.isEmpty, "an interrupted gesture sent a move")
        h.expectEveryRowAtRest(drags ? "a drag after the window resigned key" : "a press after the window resigned key")
    }

    @Test(arguments: [false, true])
    func theAppDeactivatingEndsIt(_ drags: Bool) throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness()
        defer { h.close() }
        _ = try press(h, drags: drags)
        h.list.pointerFocusLost() // what the list's `NSApplication.didResignActiveNotification` observer runs
        h.finishFlights()
        #expect(h.drops.isEmpty, "an interrupted gesture sent a move")
        h.expectEveryRowAtRest(drags ? "a drag after the app deactivated" : "a press after the app deactivated")
    }

    @Test(arguments: [false, true])
    func escapeEndsIt(_ drags: Bool) throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness()
        defer { h.close() }
        _ = try press(h, drags: drags)
        h.list.keyDown(with: try h.escape())
        h.finishFlights()
        #expect(h.drops.isEmpty, "a cancelled gesture sent a move")
        h.expectEveryRowAtRest(drags ? "a drag after Escape" : "a press after Escape")
    }

    /// The release went to a view of this window outside the list (the source left under the pointer, the list
    /// reloaded under the drag): after its dispatch the held drag has lost its release, and it ends as a cancel.
    @Test func aReleaseThatNeverReachesTheDragEndsIt() async throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness()
        defer { h.close() }
        let pin = try press(h, drags: true)
        let release = try h.event(.leftMouseUp, on: pin, down: 40)
        _ = h.list.pointerEventSeen(.leftMouseUp, in: h.window, at: h.window.convertPoint(toScreen: release.locationInWindow))
        try #require(h.window.contentView).mouseUp(with: release)
        // The release's dispatch is over: the list's check after it runs on the next main-queue turns.
        for _ in 0..<4 { await Task.yield() }
        h.finishFlights()
        #expect(h.drops.isEmpty, "a lost release sent a move")
        h.expectEveryRowAtRest("a drag whose release never reached it")
    }

    /// The release went to another app's window (outside this one): the drag ends after that dispatch.
    @Test func aReleaseOutsideTheWindowEndsIt() async throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness()
        defer { h.close() }
        _ = try press(h, drags: true)
        _ = h.list.pointerEventSeen(.leftMouseUp, in: nil, at: NSPoint(x: -400, y: -400))
        for _ in 0..<4 { await Task.yield() }
        h.finishFlights()
        #expect(h.drops.isEmpty, "a release outside the window sent a move")
        h.expectEveryRowAtRest("a drag released outside the window")
    }
}
