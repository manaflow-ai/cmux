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
    @Test func wakeRecoveryRebuildsAStalePresentedRenderer() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let initialRebuildCount = rendererRebuildCallCount()

        fixture.surface.recoverRendererAfterWake(reason: "test.displayWake")

        #expect(rendererRebuildCallCount() == initialRebuildCount + 1)
    }

    @Test func wakeRecoveryWaitsForPresentationReadiness() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface
        let initialRebuildCount = rendererRebuildCallCount()
        surface.markShellExited()
        surface.paneHost.frame = .zero
        surface.surfaceView.frame = .zero

        surface.recoverRendererAfterWake(reason: "test.displayWake")

        #expect(rendererRebuildCallCount() == initialRebuildCount)
        surface.paneHost.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        surface.surfaceView.frame = surface.paneHost.bounds
        surface.rendererPresentationReadinessDidChange()

        #expect(rendererRebuildCallCount() == initialRebuildCount + 1)
        #expect(surface.renderHealth == .shellExited)
    }

    @Test func windowShowCanRecoverAfterAnEarlierEpisodeWasExhausted() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface

        surface.setRendererPortalVisible(false, presentationReady: true)
        surface.setRendererPortalVisible(true, presentationReady: true)
        failProbe(on: surface)
        failProbe(on: surface)
        #expect(surface.renderHealth == .notRendering)

        surface.setRendererWindowVisible(false)
        surface.setRendererWindowVisible(true)
        #expect(surface.rendererPresentationState.inFlightToken != nil)

        failProbe(on: surface)
        #expect(surface.renderHealth == .awaitingFrame)
    }

    private func failProbe(on surface: TerminalSurface) {
        #expect(cmux_test_ghostty_renderer_fail(
            surface.runtimeSurfacePointer,
            Int32(GHOSTTY_RENDER_PRESENTATION_BACKEND_FAILED.rawValue)
        ))
    }
}
