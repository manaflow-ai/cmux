import AppKit
import GhosttyKit
import Testing
@testable import CmuxTerminal

/// Visibility transitions begin a fresh bounded recovery episode.
@MainActor
@Suite(.serialized) struct TerminalSurfaceRendererLifecycleTests {
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
        surface.failRendererPresentationForTesting(status: GHOSTTY_RENDER_PRESENTATION_BACKEND_FAILED)
    }
}
