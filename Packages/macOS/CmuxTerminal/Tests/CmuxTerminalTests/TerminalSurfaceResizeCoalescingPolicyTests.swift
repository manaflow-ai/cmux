import Testing
@testable import CmuxTerminal

@Suite
struct TerminalSurfaceResizeCoalescingPolicyTests {
    @Test
    func interactivePaneResizeUsesPixelOnlyCoalescing() {
        #expect(
            TerminalSurface.shouldCoalesceSurfacePixelResize(
                windowLiveResizeActive: false,
                interactiveGeometryResizeActive: true,
                bypass: false
            )
        )
        #expect(
            TerminalSurface.shouldCoalesceSurfacePixelResize(
                windowLiveResizeActive: true,
                interactiveGeometryResizeActive: false,
                bypass: false
            )
        )
        #expect(
            !TerminalSurface.shouldCoalesceSurfacePixelResize(
                windowLiveResizeActive: false,
                interactiveGeometryResizeActive: true,
                bypass: true
            )
        )
    }
}
