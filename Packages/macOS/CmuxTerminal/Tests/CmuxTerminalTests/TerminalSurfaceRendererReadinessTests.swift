import AppKit
import CmuxTerminalCore
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
        surface.noteRendererPresentationReadinessGeometry(surface.committedPaneGeometry)
        surface.rendererPresentationState.recoveryAttempted = true
        surface.renderHealth = .notRendering

        surface.committedPaneGeometry = TerminalPaneGeometry(
            size: CGSize(width: 640, height: 480),
            backingScale: 2,
            phase: .settled
        )
        surface.noteRendererPresentationReadinessGeometry(surface.committedPaneGeometry)

        #expect(surface.renderHealth == .awaitingFrame)
        #expect(!surface.rendererPresentationState.recoveryAttempted)
    }
}
