import Testing

@testable import CmuxAgentChatUI

@Suite("Artifact text jump convergence")
struct ChatArtifactTextJumpConvergenceTests {
    @Test("retargets a stale laid-out window until the requested boundary is stable")
    func retargetsUntilStable() {
        var top = ChatArtifactTextJumpConvergence(initialTargetOffset: 0)
        #expect(top.decision(observedOffset: 149_188, targetOffset: 0) == .retarget(offset: 0))
        #expect(top.decision(observedOffset: 0, targetOffset: 0) == .finish)

        var end = ChatArtifactTextJumpConvergence(initialTargetOffset: 19_200)
        #expect(end.decision(observedOffset: 19_200, targetOffset: 168_000) == .retarget(offset: 168_000))
        #expect(end.decision(observedOffset: 168_000, targetOffset: 168_000) == .finish)
    }

    @Test("forces the latest boundary after the bounded retarget budget")
    func boundsRetargeting() {
        var convergence = ChatArtifactTextJumpConvergence(
            initialTargetOffset: 20_000,
            maximumRetargetCount: 1
        )

        #expect(convergence.decision(observedOffset: 20_000, targetOffset: 40_000) == .retarget(offset: 40_000))
        #expect(convergence.decision(observedOffset: 40_000, targetOffset: 80_000) == .force(offset: 80_000))
    }
}
