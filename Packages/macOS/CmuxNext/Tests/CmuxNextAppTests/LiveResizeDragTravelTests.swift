import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S7: a live-resize drag that replaces one waiting for the frame tick carries the replaced drag's
/// pointer travel in its deltas (`LiveResizeDragInput.carrying`), so a gesture that reads deltas, not the location,
/// moves as far as the pointer did. The carried drag keeps the newest drag's type, window and location. The rig's
/// drags have no deltas of their own, so the frame-tick tests never make a copy; this test does, with a window's drag.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct LiveResizeDragTravelTests {
    @Test func aCarriedDragHasTheTravelOfTheDragsItReplacedAndTheNewestPlace() {
        let rig = WindowLiveResizeFrameTickTests.Rig()
        defer { rig.close() }
        let newest = rig.event(.leftMouseDragged, CGPoint(x: 300, y: 200))
        let carried = LiveResizeDragInput.carrying(newest, dx: 7, dy: -3)
        #expect(carried !== newest, "a window's drag could not carry travel: the copy was refused")
        #expect(carried.deltaX == newest.deltaX + 7 && carried.deltaY == newest.deltaY - 3,
                "deltas \(carried.deltaX), \(carried.deltaY); the newest drag's \(newest.deltaX), \(newest.deltaY)")
        #expect(carried.type == .leftMouseDragged && carried.windowNumber == newest.windowNumber, "type \(carried.type), window \(carried.windowNumber)")
        #expect(carried.locationInWindow == newest.locationInWindow, "location \(carried.locationInWindow), newest \(newest.locationInWindow)")
        #expect(LiveResizeDragInput.carrying(newest, dx: 0, dy: 0) === newest, "no travel to carry: the drag itself")
    }
}
