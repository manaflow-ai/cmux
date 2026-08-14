import Testing
@testable import CmuxTerminal

@Suite
struct TerminalSurfaceResizeCoalescingPolicyTests {
    @Test
    func interactivePaneResizeUsesPixelOnlyCoalescing() {
        #expect(
            TerminalSurfaceResizeCoalescingPolicy(
                windowLiveResizeActive: false,
                interactiveGeometryResizeActive: true,
                bypass: false
            ).shouldCoalescePixelOnlyResize
        )
        #expect(
            TerminalSurfaceResizeCoalescingPolicy(
                windowLiveResizeActive: true,
                interactiveGeometryResizeActive: false,
                bypass: false
            ).shouldCoalescePixelOnlyResize
        )
        #expect(
            !TerminalSurfaceResizeCoalescingPolicy(
                windowLiveResizeActive: false,
                interactiveGeometryResizeActive: true,
                bypass: true
            ).shouldCoalescePixelOnlyResize
        )
    }
}
