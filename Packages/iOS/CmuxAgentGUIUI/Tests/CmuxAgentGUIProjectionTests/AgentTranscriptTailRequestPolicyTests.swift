#if os(iOS)
import Testing

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
}
#endif
