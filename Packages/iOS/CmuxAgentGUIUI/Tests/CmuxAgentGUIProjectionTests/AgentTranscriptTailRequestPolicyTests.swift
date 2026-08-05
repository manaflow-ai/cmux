#if os(iOS)
import Testing
import CmuxAgentChatUI

@testable import CmuxAgentGUIUI

@Suite("Agent transcript tail request policy")
struct AgentTranscriptTailRequestPolicyTests {
    @Test("loaded tail jumps locally without waiting for semantic paging")
    func loadedTailUsesLocalScroll() {
        #expect(AgentTranscriptTailRequestPolicy.action(hasMoreAfter: false) == .localScroll)
    }

    @Test("paged newer history uses authoritative semantic tail")
    func pagedTailUsesSemanticTail() {
        #expect(AgentTranscriptTailRequestPolicy.action(hasMoreAfter: true) == .semanticTail)
    }

    @Test("local tail waits for native viewport confirmation before attaching")
    func localTailPreservesDetachedFollowStateBeforeCommand() {
        let current = ConversationFollowState<String>.detached(
            anchorID: "middle-row",
            offset: 24,
            unseenCount: 3
        )

        #expect(
            AgentTranscriptTailRequestPolicy.followStateBeforeCommand(
                current: current,
                action: .localScroll
            ) == current
        )
    }

    @Test("semantic tail marks the pending authoritative load")
    func semanticTailMarksJumpingBeforeCommand() {
        let current = ConversationFollowState<String>.detached(
            anchorID: "middle-row",
            offset: 24,
            unseenCount: 3
        )

        #expect(
            AgentTranscriptTailRequestPolicy.followStateBeforeCommand(
                current: current,
                action: .semanticTail
            ) == .jumpingToTail
        )
    }
}
#endif
