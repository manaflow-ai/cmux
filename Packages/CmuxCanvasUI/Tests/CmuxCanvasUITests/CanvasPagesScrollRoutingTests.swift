import Testing
@testable import CmuxCanvasUI

@Suite("CanvasPagesScrollRouting")
struct CanvasPagesScrollRoutingTests {
    @Test func shiftWheelRoutesToNativePages() {
        #expect(CanvasPagesScrollRouting().shouldRouteToNativePages(
            deltaX: 0,
            deltaY: -1,
            isShiftPressed: true
        ))
    }

    @Test func verticalWheelWithoutShiftStaysWithSurfaceContent() {
        #expect(!CanvasPagesScrollRouting().shouldRouteToNativePages(
            deltaX: 0,
            deltaY: -10,
            isShiftPressed: false
        ))
    }

    @Test func dominantHorizontalWheelRoutesToNativePages() {
        #expect(CanvasPagesScrollRouting().shouldRouteToNativePages(
            deltaX: -12,
            deltaY: 1,
            isShiftPressed: false
        ))
    }

    @Test func dominantVerticalTrackpadMovementStaysWithSurfaceContent() {
        #expect(!CanvasPagesScrollRouting().shouldRouteToNativePages(
            deltaX: -3,
            deltaY: -18,
            isShiftPressed: false
        ))
    }
}
