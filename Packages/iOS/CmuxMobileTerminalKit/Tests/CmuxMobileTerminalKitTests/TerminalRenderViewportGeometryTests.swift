import CoreGraphics
import Testing
@testable import CmuxMobileTerminalKit

@Suite("Terminal render viewport geometry")
struct TerminalRenderViewportGeometryTests {
    @Test("stale live viewport clamp cannot collapse below target layout height")
    func clampDoesNotShrinkBelowTarget() {
        let layout = CGRect(x: 4, y: 8, width: 390, height: 420)
        let transientOneRowLive = CGRect(x: 100, y: 200, width: 111, height: 18)
        let staleOvershootLive = CGRect(x: 100, y: 200, width: 111, height: 500)

        let transient = TerminalRenderViewportGeometry(
            layoutViewportRect: layout,
            liveViewportRect: transientOneRowLive
        )
        #expect(transient.viewportRect(
            forRenderSize: layout.size,
            clampsStaleLiveViewport: true
        ) == layout)
        #expect(transient.viewportRect(
            forRenderSize: layout.size,
            clampsStaleLiveViewport: false
        ).height == 18)

        let overshoot = TerminalRenderViewportGeometry(
            layoutViewportRect: layout,
            liveViewportRect: staleOvershootLive
        )
        #expect(overshoot.viewportRect(
            forRenderSize: layout.size,
            clampsStaleLiveViewport: true
        ) == layout)
    }

    @Test("stale live viewport clamp preserves legitimate smaller animation heights")
    func clampPreservesLegitimateSmallerLiveHeight() {
        let layout = CGRect(x: 4, y: 8, width: 390, height: 840)
        let live = CGRect(x: 100, y: 200, width: 111, height: 420)
        let geometry = TerminalRenderViewportGeometry(
            layoutViewportRect: layout,
            liveViewportRect: live
        )

        #expect(geometry.viewportRect(
            forRenderSize: layout.size,
            clampsStaleLiveViewport: true
        ).height == 420)
    }

    @Test("stale live viewport clamp preserves below-threshold animation heights")
    func clampPreservesBelowThresholdAnimationHeight() {
        let layout = CGRect(x: 4, y: 8, width: 390, height: 840)
        let live = CGRect(x: 100, y: 200, width: 111, height: 160)
        let geometry = TerminalRenderViewportGeometry(
            layoutViewportRect: layout,
            liveViewportRect: live
        )

        #expect(geometry.viewportRect(
            forRenderSize: layout.size,
            clampsStaleLiveViewport: true
        ).height == 160)
    }

    @Test("render viewport height floors at one point")
    func viewportHeightFloorsAtOnePoint() {
        let layout = CGRect(x: 4, y: 8, width: 390, height: 0)
        let live = CGRect(x: 100, y: 200, width: 111, height: 0)
        let geometry = TerminalRenderViewportGeometry(
            layoutViewportRect: layout,
            liveViewportRect: live
        )

        #expect(geometry.viewportRect(
            forRenderSize: layout.size,
            clampsStaleLiveViewport: true
        ).height == 1)
        #expect(geometry.viewportRect(
            forRenderSize: layout.size,
            clampsStaleLiveViewport: false
        ).height == 1)
    }
}
