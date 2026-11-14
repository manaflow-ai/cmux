import AppKit
import GhosttyKit
import CmuxTerminalGhosttyRuntimeTestStubs
import Testing
@testable import CmuxTerminal

@_silgen_name("cmux_test_ghostty_renderer_rebuild_call_count")
private func rendererRebuildCallCount() -> UInt32

/// Visibility transitions begin a fresh bounded recovery episode.
@MainActor
@Suite(.serialized) struct TerminalSurfaceRendererLifecycleTests {
    /// Verifies that hiding and showing the hosting window after an exhausted recovery episode rebuilds the renderer.
    @Test func windowShowCanRecoverAfterAnEarlierEpisodeWasExhausted() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface

        surface.setRendererPortalVisible(false, presentationReady: true)
        surface.setRendererPortalVisible(true, presentationReady: true)
        failProbe(on: surface)
        failProbe(on: surface)
        #expect(surface.renderHealth == .notRendering)
        #expect(rendererRebuildCallCount() == 0)

        surface.setRendererWindowVisible(false)
        surface.setRendererWindowVisible(true)
        #expect(rendererRebuildCallCount() == 1)
        #expect(surface.rendererPresentationState.inFlightToken != nil)

        failProbe(on: surface)
        #expect(surface.renderHealth == .awaitingFrame)
    }

    /// Verifies that switching portal visibility after an exhausted recovery episode rebuilds the renderer on reveal.
    @Test func portalVisibilitySwitchRebuildsRendererAfterExhaustedRecoveryEpisode() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface

        surface.setRendererPortalVisible(false, presentationReady: true)
        surface.setRendererPortalVisible(true, presentationReady: true)
        failProbe(on: surface)
        failProbe(on: surface)
        #expect(surface.renderHealth == .notRendering)
        #expect(rendererRebuildCallCount() == 0)

        surface.ensureRendererPresented(presentationReady: true)
        #expect(rendererRebuildCallCount() == 0)

        surface.setRendererPortalVisible(false, presentationReady: true)
        surface.setRendererPortalVisible(true, presentationReady: true)
        #expect(rendererRebuildCallCount() == 1)
        #expect(surface.renderHealth == .awaitingFrame)
        fixture.acknowledgePendingPresentation()
        #expect(surface.renderHealth == .rendering)
        #expect(surface.isRendererPresented)
    }

    /// Verifies that a child exit during an exhausted recovery episode retains the presented frame unless the renderer is explicitly released.
    @Test func shellExitAfterExhaustedRecoveryRetainsPresentedFrameUntilReleased() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface

        surface.setRendererPortalVisible(false, presentationReady: true)
        surface.setRendererPortalVisible(true, presentationReady: true)
        failProbe(on: surface)
        failProbe(on: surface)
        #expect(surface.renderHealth == .notRendering)

        surface.markShellExited()
        #expect(surface.renderHealth == .shellExited)
        #expect(surface.isRendererPresented)

        surface.ensureRendererPresented(presentationReady: true)
        #expect(rendererRebuildCallCount() == 0)

        surface.setRendererPortalVisible(false, presentationReady: true)
        surface.setRendererPortalVisible(true, presentationReady: true)
        #expect(rendererRebuildCallCount() == 0)
        #expect(surface.isRendererPresented)

        surface.setRendererPortalVisible(false, presentationReady: true)
        #expect(surface.releaseRenderer())
        surface.setRendererPortalVisible(true, presentationReady: true)
        #expect(rendererRebuildCallCount() == 1)
    }

    /// Simulates a failed presentation probe on the given surface.
    private func failProbe(on surface: TerminalSurface) {
        #expect(cmux_test_ghostty_renderer_fail(
            surface.runtimeSurfacePointer,
            Int32(GHOSTTY_RENDER_PRESENTATION_BACKEND_FAILED.rawValue)
        ))
    }
}
