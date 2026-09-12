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

        surface.setRendererWindowVisible(false)
        surface.setRendererWindowVisible(true)
        failProbe(on: surface)
        failProbe(on: surface)
        #expect(surface.renderHealth == .notRendering)

        surface.setRendererWindowVisible(false)
        #expect(surface.renderHealth == .notStarted)
        surface.setRendererWindowVisible(true)
        #expect(surface.rendererPresentationState.inFlightToken != nil)

        failProbe(on: surface)
        #expect(surface.renderHealth == .awaitingFrame)
    }

    private func failProbe(on surface: TerminalSurface) {
        guard let token = surface.rendererPresentationState.inFlightToken else {
            Issue.record("expected an in-flight presentation probe")
            return
        }
        surface.rendererFrameDidFail(
            token: token,
            status: GHOSTTY_RENDER_PRESENTATION_BACKEND_FAILED
        )
    }
}
