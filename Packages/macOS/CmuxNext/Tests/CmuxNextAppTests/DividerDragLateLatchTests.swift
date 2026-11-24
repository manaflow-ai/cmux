import AppKit
@testable import CmuxNextLayout
import Testing

/// A divider drag's frame tick writes the live pointer when it is ahead of the last delivered event (late latch, Leo:
/// "i want all our resizing at any cpu to be able to happen in lockstep"): on a busy main thread the moves queue, and
/// the divider would land where the pointer was frames ago.
struct DividerDragLateLatchTests {
    @Test func aPointerAheadOfItsEventsIsWritten() {
        let live = NSPoint(x: 420, y: 300)
        #expect(DividerDrag.latched(event: NSPoint(x: 400, y: 300), live: live, buttonDown: true) == live)
    }

    @Test func eventsThatCaughtUpKeepTheirPoint() {
        #expect(DividerDrag.latched(event: NSPoint(x: 400, y: 300), live: NSPoint(x: 400.1, y: 300), buttonDown: true) == nil)
    }

    @Test func aSyntheticDragWithNoButtonDownKeepsItsEventsPoint() {
        #expect(DividerDrag.latched(event: NSPoint(x: 400, y: 300), live: NSPoint(x: 10, y: 10), buttonDown: false) == nil)
    }

    @Test func aNonFiniteLivePointIsIgnored() {
        #expect(DividerDrag.latched(event: .zero, live: NSPoint(x: CGFloat.nan, y: 0), buttonDown: true) == nil)
    }
}
