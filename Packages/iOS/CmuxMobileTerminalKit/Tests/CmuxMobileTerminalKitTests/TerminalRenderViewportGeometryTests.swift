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
        #expect(transient.viewportRect(clampsStaleLiveViewport: true) == layout)
        #expect(transient.viewportRect(clampsStaleLiveViewport: false).height == 18)

        let overshoot = TerminalRenderViewportGeometry(
            layoutViewportRect: layout,
            liveViewportRect: staleOvershootLive
        )
        #expect(overshoot.viewportRect(clampsStaleLiveViewport: true) == layout)
    }

    @Test("render viewport height floors at one point")
    func viewportHeightFloorsAtOnePoint() {
        let layout = CGRect(x: 4, y: 8, width: 390, height: 0)
        let live = CGRect(x: 100, y: 200, width: 111, height: 0)
        let geometry = TerminalRenderViewportGeometry(
            layoutViewportRect: layout,
            liveViewportRect: live
        )

        #expect(geometry.viewportRect(clampsStaleLiveViewport: true).height == 1)
        #expect(geometry.viewportRect(clampsStaleLiveViewport: false).height == 1)
    }
}
