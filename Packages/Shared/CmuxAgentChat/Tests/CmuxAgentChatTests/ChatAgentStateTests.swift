import CmuxAgentChat
import Foundation
import Testing

struct ChatAgentStateTests {
    @Test("explicit input advances needs input to working")
    func explicitInputAdvancesNeedsInput() {
        let at = Date(timeIntervalSince1970: 42)
        #expect(
            ChatAgentState.needsInput(since: Date(timeIntervalSince1970: 41)).afterExplicitInput(at: at)
                == .working(since: at)
        )
    }

    @Test("explicit input leaves non-blocking states unchanged")
    func explicitInputLeavesOtherStatesUnchanged() {
        let at = Date(timeIntervalSince1970: 42)
        #expect(ChatAgentState.idle.afterExplicitInput(at: at) == .idle)
        #expect(ChatAgentState.working(since: at).afterExplicitInput(at: at) == .working(since: at))
        #expect(ChatAgentState.failed(since: at, reason: "quota").afterExplicitInput(at: at) == .working(since: at))
        #expect(ChatAgentState.ended.afterExplicitInput(at: at) == .ended)
    }

    @Test("failed state requests attention and round trips its reason")
    func failedStateIsRetryableAndCodable() throws {
        let state = ChatAgentState.failed(
            since: Date(timeIntervalSince1970: 42),
            reason: "The provider rejected the request"
        )
        #expect(state.needsAttention)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let encoded = try encoder.encode(state)
        #expect(try decoder.decode(ChatAgentState.self, from: encoded) == state)
    }
}
