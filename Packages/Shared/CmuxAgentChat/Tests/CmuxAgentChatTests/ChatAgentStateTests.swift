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
        #expect(ChatAgentState.ended.afterExplicitInput(at: at) == .ended)
    }
}
