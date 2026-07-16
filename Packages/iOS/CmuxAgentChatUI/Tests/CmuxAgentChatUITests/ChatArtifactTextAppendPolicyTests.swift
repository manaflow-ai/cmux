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

    @Test("protects an animated top jump from streamed appends")
    func defersProgrammaticScrollAppends() {
        var policy = ChatArtifactTextAppendPolicy()

        policy.beginProgrammaticAnimation()
        #expect(policy.enqueue(chunkCount: 2) == 0)
        #expect(policy.endProgrammaticAnimation() == 2)
    }
}
