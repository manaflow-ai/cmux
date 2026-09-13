import AppKit
import GhosttyKit
import GhosttyRuntimeTestStubs
import Testing
@testable import CmuxTerminal

/// Visibility transitions begin a fresh bounded recovery episode.
extension TerminalRendererTests {
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
        guard surface.rendererPresentationState.inFlightToken != nil else {
            Issue.record("expected an in-flight presentation probe")
            return
        }
        guard let runtimeSurface = surface.surface else {
            Issue.record("expected a live runtime surface")
            return
        }
        #expect(cmux_test_ghostty_renderer_fail(
            runtimeSurface,
            Int32(GHOSTTY_RENDER_PRESENTATION_BACKEND_FAILED.rawValue)
        ))
    }
}

}
