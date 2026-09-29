import CmuxTerminalCore
import CoreGraphics
import Testing
@testable import CmuxTerminal

/// Regression coverage for a visible renderer whose first frame was rejected
/// while its pane geometry was still settling.
@MainActor
@Suite(.serialized) struct TerminalSurfaceRendererReadinessTests {
    @Test func geometryCommitStartsANewPresentationEpisodeAfterFailure() {
        let previous = TerminalRendererPresentationGeometry(TerminalPaneGeometry(
            size: CGSize(width: 800, height: 600),
            backingScale: 2,
            phase: .settled
        ))
        let current = TerminalRendererPresentationGeometry(TerminalPaneGeometry(
            size: CGSize(width: 640, height: 480),
            backingScale: 2,
            phase: .settled
        ))
        let decision = TerminalRendererPresentationReadinessDecision(
            previous: previous,
            current: current,
            renderHealth: .notRendering,
            hasInFlightToken: false
        )

        #expect(decision.geometryChanged)
        #expect(decision.shouldAwaitFrame)
    }

    @Test func unchangedGeometryDoesNotReopenAnExhaustedEpisode() {
        let geometry = TerminalRendererPresentationGeometry(TerminalPaneGeometry(
            size: CGSize(width: 800, height: 600),
            backingScale: 2,
            phase: .settled
        ))
        let decision = TerminalRendererPresentationReadinessDecision(
            previous: geometry,
            current: geometry,
            renderHealth: .notRendering,
            hasInFlightToken: false
        )

        #expect(!decision.geometryChanged)
        #expect(!decision.shouldAwaitFrame)
    }
}
