import AppKit
import CmuxTerminalCore
import GhosttyKit
import GhosttyRuntimeTestStubs
import Testing
@testable import CmuxTerminal

/// Exercises the C callback boundary used by tokened renderer probes. The
/// presentation state tests cover the state machine directly; these tests keep
/// registration, userdata routing, and token forwarding in the same contract.
extension TerminalRendererTests {
@MainActor
@Suite(.serialized) struct TerminalSurfaceRendererCallbackTests {
    @Test func registeredPresentationCallbackAcknowledgesThePendingToken() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface

        surface.rendererRuntimeSurfaceDidCreate(presentationReady: true)
        #expect(surface.renderHealth == .awaitingFrame)
        #expect(cmux_test_ghostty_renderer_present(fixture.runtimeSurface))
        #expect(surface.renderHealth == .rendering)
        #expect(surface.isRendererPresented)
    }

    @Test func registeredFailureCallbackForwardsTokenAndTriggersOneRecoveryProbe() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface

        surface.rendererRuntimeSurfaceDidCreate(presentationReady: true)
        #expect(cmux_test_ghostty_renderer_fail(
            fixture.runtimeSurface,
            Int32(GHOSTTY_RENDER_PRESENTATION_BACKEND_FAILED.rawValue)
        ))
        #expect(surface.renderHealth == .awaitingFrame)
        #expect(cmux_test_ghostty_renderer_fail(
            fixture.runtimeSurface,
            Int32(GHOSTTY_RENDER_PRESENTATION_DISCARDED.rawValue)
        ))
        #expect(surface.renderHealth == .notRendering)
    }

    @Test func shellExitHealthSurvivesRendererRebuildAndPresentation() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface

        surface.markShellExited()
        surface.setRendererWindowVisible(false)
        #expect(surface.releaseRenderer())
        #expect(surface.renderHealth == .shellExited)

        surface.setRendererWindowVisible(true)
        #expect(surface.renderHealth == .shellExited)
        #expect(cmux_test_ghostty_renderer_present(fixture.runtimeSurface))
        #expect(surface.renderHealth == .shellExited)
        #expect(surface.isRendererPresented)

        surface.retryRendererPresentationAfterActivity(presentationReady: true)
        #expect(surface.renderHealth == .shellExited)
        surface.setRendererWindowVisible(false)
        #expect(surface.releaseRenderer())
        surface.setRendererWindowVisible(true)
        #expect(cmux_test_ghostty_renderer_fail(
            fixture.runtimeSurface,
            Int32(GHOSTTY_RENDER_PRESENTATION_BACKEND_FAILED.rawValue)
        ))
        #expect(surface.renderHealth == .shellExited)
    }
}

}
