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
                bypass: false,
                surfaceKind: .processOwned
            ).shouldCoalescePixelOnlyResize
        )
        #expect(
            TerminalSurfaceResizeCoalescingPolicy(
                windowLiveResizeActive: true,
                interactiveGeometryResizeActive: false,
                bypass: false,
                surfaceKind: .processOwned
            ).shouldCoalescePixelOnlyResize
        )
        #expect(
            !TerminalSurfaceResizeCoalescingPolicy(
                windowLiveResizeActive: false,
                interactiveGeometryResizeActive: true,
                bypass: true,
                surfaceKind: .processOwned
            ).shouldCoalescePixelOnlyResize
        )
    }

    @Test
    func processOwnedSurfaceCoalescesStableGridPixelChurn() {
        #expect(
            TerminalSurfaceResizeCoalescingPolicy(
                windowLiveResizeActive: false,
                interactiveGeometryResizeActive: false,
                bypass: false,
                surfaceKind: .processOwned
            ).shouldCoalescePixelOnlyResize
        )
    }

    @Test
    func manualIOSurfaceKeepsInteractionOnlyCoalescing() {
        #expect(
            !TerminalSurfaceResizeCoalescingPolicy(
                windowLiveResizeActive: false,
                interactiveGeometryResizeActive: false,
                bypass: false,
                surfaceKind: .manualIO
            ).shouldCoalescePixelOnlyResize
        )
        #expect(
            TerminalSurfaceResizeCoalescingPolicy(
                windowLiveResizeActive: false,
                interactiveGeometryResizeActive: true,
                bypass: false,
                surfaceKind: .manualIO
            ).shouldCoalescePixelOnlyResize
        )
        #expect(
            TerminalSurfaceResizeCoalescingPolicy(
                windowLiveResizeActive: true,
                interactiveGeometryResizeActive: false,
                bypass: false,
                surfaceKind: .manualIO
            ).shouldCoalescePixelOnlyResize
        )
    }
}
