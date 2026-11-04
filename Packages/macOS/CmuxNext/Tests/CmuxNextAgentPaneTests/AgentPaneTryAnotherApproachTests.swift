import Foundation
import Testing

@testable import CmuxNextAgentPane

@Suite struct AgentPaneTryAnotherApproachTests {
    @Test func decodesOnlyPositiveTurnSequences() {
        #expect(AgentPaneRequest(body: ["method": "chat.tryAnotherApproach", "params": ["throughSeq": 6]])
            == .tryAnotherApproach(.init(params: ["throughSeq": 6])!))
        #expect(AgentPaneRequest(body: ["method": "chat.tryAnotherApproach", "params": ["throughSeq": 0]])
            == .unsupported("chat.tryAnotherApproach"))
        #expect(AgentPaneRequest(body: ["method": "chat.tryAnotherApproach", "params": ["throughSeq": 6, "extra": true]])
            == .unsupported("chat.tryAnotherApproach"))
    }
}
