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
        acknowledgePendingPresentation(on: surface)

        failProbe(on: surface)

        surface.committedPaneGeometry = TerminalPaneGeometry(
            size: CGSize(width: 640, height: 480),
            backingScale: 2,
            phase: .settled
        )
        surface.rendererPresentationReadinessDidChange()

        #expect(surface.renderHealth == .awaitingFrame)
        failProbe(on: surface)
        acknowledgePendingPresentation(on: surface)
        #expect(surface.renderHealth == .rendering)
        #expect(surface.isRendererPresented)
    }

    private func acknowledgePendingPresentation(on surface: TerminalSurface) {
        guard let token = surface.rendererPresentationState.inFlightToken else {
            Issue.record("Expected a tokened presentation probe")
            return
        }
        surface.rendererFrameDidPresent(token: token)
    }

    private func failProbe(on surface: TerminalSurface) {
        guard let token = surface.rendererPresentationState.inFlightToken else {
            Issue.record("Expected a tokened presentation probe")
            return
        }
        surface.rendererFrameDidFail(
            token: token,
            status: GHOSTTY_RENDER_PRESENTATION_BACKEND_FAILED
        )
    }
}
