import AppKit
import CmuxTerminalCore
import GhosttyKit
import CmuxTerminalGhosttyRuntimeTestStubs
import Testing
@testable import CmuxTerminal

@_silgen_name("cmux_test_ghostty_renderer_rebuild_call_count")
private func rendererRebuildCallCount() -> UInt32
@_silgen_name("cmux_test_ghostty_renderer_realized_set_result")
private func setRendererRealizedResult(_ result: Bool)

/// Exercises the C callback boundary used by tokened renderer probes. The
/// presentation state tests cover the state machine directly; these tests keep
/// registration, userdata routing, and token forwarding in the same contract.
@MainActor
@Suite(.serialized) struct TerminalSurfaceRendererCallbackTests {
    /// Verifies that a tokened presentation callback marks the surface as rendering.
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

    /// Verifies that a failed presentation probe rebuilds the renderer once and requests one recovery probe.
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
        #expect(rendererRebuildCallCount() == 1)
        #expect(cmux_test_ghostty_renderer_fail(
            fixture.runtimeSurface,
            Int32(GHOSTTY_RENDER_PRESENTATION_DISCARDED.rawValue)
        ))
        #expect(surface.renderHealth == .notRendering)
        #expect(rendererRebuildCallCount() == 1)
    }

    /// Verifies that a presented recovery probe restores rendering health after the recovery rebuild.
    @Test func recoveryProbePresentationRestoresRenderingHealthAfterRebuild() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface

        surface.rendererRuntimeSurfaceDidCreate(presentationReady: true)
        #expect(cmux_test_ghostty_renderer_fail(
            fixture.runtimeSurface,
            Int32(GHOSTTY_RENDER_PRESENTATION_BACKEND_FAILED.rawValue)
        ))
        #expect(surface.renderHealth == .awaitingFrame)
        #expect(rendererRebuildCallCount() == 1)
        #expect(cmux_test_ghostty_renderer_present(fixture.runtimeSurface))
        #expect(surface.renderHealth == .rendering)
        #expect(surface.isRendererPresented)
    }

    /// Verifies that a rejected recovery rebuild remains retryable and recovers after the renderer mailbox drains.
    @Test func rejectedRecoveryRebuildRetriesAfterRendererMailboxDrains() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface
        let scheduler = FakeRendererRealizationScheduler()
        let callbackContext = makeRendererCallbackContextForTesting(on: surface) { surfaceID in
            MainActor.assumeIsolated {
                scheduler.scheduleRendererPresentationRepair(surfaceID: surfaceID)
            }
        }
        registerRendererCallbacksForTesting(on: surface, runtimeSurface: fixture.runtimeSurface)

        surface.rendererRuntimeSurfaceDidCreate(presentationReady: true)
        setRendererRealizedResult(false)
        #expect(cmux_test_ghostty_renderer_fail(
            fixture.runtimeSurface,
            Int32(GHOSTTY_RENDER_PRESENTATION_BACKEND_FAILED.rawValue)
        ))
        #expect(!surface.isRendererPresented)
        #expect(rendererRebuildCallCount() == 1)
        #expect(scheduler.scheduledSurfaceIDs.isEmpty)

        setRendererRealizedResult(true)
        scheduler.onSchedule = { surfaceID in
            #expect(surfaceID == surface.id)
            surface.retryRendererPresentationAfterActivity(presentationReady: true)
        }
        terminalRendererEventCallback(
            callbackContext.toOpaque(),
            GHOSTTY_RENDERER_EVENT_UPDATE_FRAME_END
        )

        #expect(scheduler.scheduledSurfaceIDs == [surface.id])
        #expect(rendererRebuildCallCount() == 2)
        #expect(surface.renderHealth == .awaitingFrame)
        #expect(cmux_test_ghostty_renderer_present(fixture.runtimeSurface))
        #expect(surface.renderHealth == .rendering)
        #expect(surface.isRendererPresented)
    }

    /// Verifies that shell-exited health survives renderer rebuilds and presentation probes.
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
