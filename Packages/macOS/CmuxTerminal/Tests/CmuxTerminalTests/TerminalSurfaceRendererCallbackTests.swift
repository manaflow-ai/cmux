import AppKit
import CmuxTerminalCore
import GhosttyKit
import GhosttyRuntimeTestStubs
import Testing
@testable import CmuxTerminal

/// Exercises the C callback boundary used by tokened renderer probes. The
/// presentation state tests cover the state machine directly; these tests keep
/// registration, userdata routing, and token forwarding in the same contract.
@MainActor
@Suite(.serialized) struct TerminalSurfaceRendererCallbackTests {
    @Test func registeredPresentationCallbackAcknowledgesThePendingToken() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface
        let context = installCallbackContext(on: surface)

        #expect(ghostty_surface_set_render_presented_callback(
            fixture.runtimeSurface,
            terminalRendererPresentedCallback,
            context.toOpaque()
        ))
        #expect(ghostty_surface_set_render_failed_callback(
            fixture.runtimeSurface,
            terminalRendererFailedCallback,
            context.toOpaque()
        ))

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
        let context = installCallbackContext(on: surface)
        #expect(ghostty_surface_set_render_presented_callback(
            fixture.runtimeSurface,
            terminalRendererPresentedCallback,
            context.toOpaque()
        ))
        #expect(ghostty_surface_set_render_failed_callback(
            fixture.runtimeSurface,
            terminalRendererFailedCallback,
            context.toOpaque()
        ))

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
        let context = installCallbackContext(on: surface)
        #expect(ghostty_surface_set_render_presented_callback(
            fixture.runtimeSurface,
            terminalRendererPresentedCallback,
            context.toOpaque()
        ))
        #expect(ghostty_surface_set_render_failed_callback(
            fixture.runtimeSurface,
            terminalRendererFailedCallback,
            context.toOpaque()
        ))

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

    private func installCallbackContext(
        on surface: TerminalSurface
    ) -> Unmanaged<GhosttySurfaceCallbackContext> {
        let callbackTarget = TerminalSurfaceCallbackTarget(surface: surface)
        let context = Unmanaged.passRetained(GhosttySurfaceCallbackContext(
            surfaceHost: surface.surfaceView,
            surfaceController: surface,
            terminalLifecycleID: surface.terminalLifecycleId,
            rendererFramePresented: { _, token in
                MainActor.assumeIsolated {
                    callbackTarget.surface?.rendererFrameDidPresent(token: token)
                }
            },
            rendererFrameFailed: { _, token, status in
                MainActor.assumeIsolated {
                    callbackTarget.surface?.rendererFrameDidFail(token: token, status: status)
                }
            }
        ))
        surface.surfaceCallbackContext?.release()
        surface.surfaceCallbackContext = context
        return context
    }
}
