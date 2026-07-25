#if os(iOS)
import Testing

@testable import CmuxAgentGUIUI

@Suite("Agent transcript scroll pill layout policy")
struct AgentTranscriptScrollPillLayoutPolicyTests {
    @Test("keeps the baseline visual gap when no composer is overlaid")
    func baselineGapWithoutComposerOverlay() {
        #expect(AgentTranscriptScrollPillLayoutPolicy.bottomPadding(composerBottomInset: 0) == 10)
    }

    @Test("clears the composer overlay with a stable visual gap")
    func clearsComposerOverlay() {
        #expect(AgentTranscriptScrollPillLayoutPolicy.bottomPadding(composerBottomInset: 115.2) == 126)
    }

    @Test("clamps negative overlay measurements")
    func clampsNegativeOverlayMeasurements() {
        #expect(AgentTranscriptScrollPillLayoutPolicy.bottomPadding(composerBottomInset: -12) == 10)
    }
}
#endif
