import Testing

@testable import CmuxAgentChatUI

@Suite("Artifact text append policy")
struct ChatArtifactTextAppendPolicyTests {
    @Test("coalesces tracked and decelerating appends until scrolling becomes idle")
    func defersUserScrollAppends() {
        var policy = ChatArtifactTextAppendPolicy()

        #expect(policy.enqueue(chunkCount: 1) == 1)
        policy.beginTracking()
        #expect(policy.enqueue(chunkCount: 2) == 0)
        #expect(policy.endTracking(willDecelerate: true) == 0)
        #expect(policy.enqueue(chunkCount: 3) == 0)
        #expect(policy.endDecelerating() == 5)
    }

    @Test("programmatic scrolls never defer appends")
    func programmaticScrollAppendsApplyImmediately() {
        // Deferral during coordinator-owned scrolls once stranded every later
        // chunk when an end-of-animation callback was missed; animated jumps
        // are protected by convergence re-targeting instead.
        var policy = ChatArtifactTextAppendPolicy()

        policy.beginProgrammaticAnimation()
        #expect(policy.enqueue(chunkCount: 2) == 2)
        #expect(policy.endProgrammaticAnimation() == 0)
    }

    @Test("a missed end-of-animation callback cannot strand chunks")
    func missedAnimationEndDoesNotStrandChunks() {
        var policy = ChatArtifactTextAppendPolicy()

        policy.beginProgrammaticAnimation()
        // No endProgrammaticAnimation is ever delivered.
        #expect(policy.enqueue(chunkCount: 3) == 3)
        #expect(!policy.isDeferring)
    }
}
