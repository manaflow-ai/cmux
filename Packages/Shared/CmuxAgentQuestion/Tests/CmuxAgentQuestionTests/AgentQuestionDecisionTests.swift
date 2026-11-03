import CmuxAgentQuestion
import Testing

@Suite struct AgentQuestionDecisionTests {
    @Test func decisionTravelsWithSelectionsButNeverWithRecordedAnswer() throws {
        let decision: AgentQuestionJSON = ["digest": "original", "person_decision": "proof"]
        let answer = AgentQuestionAnswer(selections: ["q0": .init(optionIDs: ["o0"])], decision: decision)
        let forwarded = answer.conversationAnswer
        #expect(forwarded["decision"] == decision)
        #expect(forwarded["selections"]?["q0"]?["option_ids"] == ["o0"])
        // Old callers still encode their old wire shape; the daemon refuses an unproven answer.
        let plain = AgentQuestionAnswer(selections: answer.selections)
        #expect(plain.conversationAnswer["decision"] == nil)
    }
}
