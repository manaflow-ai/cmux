import AppKit
import CmuxTerminalCore
import GhosttyKit
import CmuxTerminalGhosttyRuntimeTestStubs
import Testing
@testable import CmuxTerminal

/// Regression coverage for a visible renderer whose first frame was rejected
/// while its pane geometry was still settling.
@MainActor
@Suite(.serialized) struct TerminalSurfaceRendererReadinessTests {
    @Test func geometryCommitStartsANewPresentationEpisodeAfterFailure() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface

        surface.committedPaneGeometry = TerminalPaneGeometry(
            size: CGSize(width: 800, height: 600),
            backingScale: 2,
            phase: .settled
        )
        surface.rendererPresentationReadinessDidChange()
        #expect(cmux_test_ghostty_renderer_present(fixture.runtimeSurface))

        failProbe(on: surface)
        failProbe(on: surface)
        #expect(surface.renderHealth == .notRendering)

        surface.committedPaneGeometry = TerminalPaneGeometry(
            size: CGSize(width: 640, height: 480),
            backingScale: 2,
            phase: .settled
        )
        surface.rendererPresentationReadinessDidChange()

        #expect(surface.renderHealth == .awaitingFrame)
        #expect(cmux_test_ghostty_renderer_present(fixture.runtimeSurface))
        #expect(surface.renderHealth == .rendering)
        #expect(surface.isRendererPresented)
    }

    private func failProbe(on surface: TerminalSurface) {
        #expect(cmux_test_ghostty_renderer_fail(
            surface.runtimeSurfacePointer,
            Int32(GHOSTTY_RENDER_PRESENTATION_BACKEND_FAILED.rawValue)
        ))
    }
}
