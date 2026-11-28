import AppKit
import Testing
@testable import CmuxNextAgentPane

/// The split spare's lifecycle must restore the full pane whenever its context becomes stale.
@MainActor
struct AgentPaneNewTabPrefetchTests {
    private let full = CGSize(width: 1000, height: 800)
    private let split = CGSize(width: 500, height: 800)

    @Test func cancellationWhileAdoptingDoesNotRenderTheNextSize() {
        #expect(AgentPaneNewTabPrefetch.step(index: 1, plan: [split, full], valid: false) == .restore)
    }

    @Test func generationOrAppearanceChangeRestoresTheParkedFullSize() {
        #expect(AgentPaneNewTabPrefetch.step(index: 0, plan: [split, full], valid: false) == .restore)
    }

    @Test func timeoutPathRestoresTheFullPaneAfterAStalledFrame() {
        #expect(AgentPaneNewTabPrefetch.step(index: 0, plan: [split, full], valid: true, timedOut: true) == .restore)
        #expect(AgentPaneNewTabPrefetch.step(index: 2, plan: [split, full], valid: true) == .finished)
        #expect(AgentPaneNewTabPrefetch.step(index: 0, plan: [split, full], valid: true) == .render(split))
    }
}
