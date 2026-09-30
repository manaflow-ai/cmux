import AppKit
import GhosttyRuntimeTestStubs
import Testing
@testable import CmuxTerminal

@MainActor
@Suite(.serialized)
struct TerminalSurfaceResizeRenderingTests {
    @Test
    func processOwnedResizeRequestsARefreshAfterApplyingTheNewGrid() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }

        cmux_test_ghostty_surface_refresh_reset()

        #expect(
            fixture.surface.updateSize(
                width: 600,
                height: 480,
                xScale: 1,
                yScale: 1,
                layerScale: 1,
                caller: "side-browser-regression"
            )
        )
        #expect(cmux_test_ghostty_surface_refresh_call_count() == 1)
    }
}
