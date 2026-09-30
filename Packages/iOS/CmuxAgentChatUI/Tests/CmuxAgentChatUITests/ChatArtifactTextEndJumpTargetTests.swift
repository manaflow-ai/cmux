import Testing

@testable import CmuxAgentChatUI

@Suite("Artifact text end jump target")
struct ChatArtifactTextEndJumpTargetTests {
    @Test("streaming targets latest and EOF targets the final end")
    func followsStreamingState() {
        #expect(ChatArtifactTextEndJumpTarget(reachedEOF: false) == .latest)
        #expect(ChatArtifactTextEndJumpTarget(reachedEOF: true) == .end)
    }
}
