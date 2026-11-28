import CmuxAgentQuestion
import Foundation
import Testing

/// The conversation owner's question part (snake_case) as the shared model,
/// and the question.answer op's answer back.
@Suite struct AgentQuestionConversationTests {
    private let part: AgentQuestionJSON = [
        "type": "question", "harness": "chief", "session": "sess_mux", "permission": "perm_1", "agent": "Chief",
        "items": [["id": "q0", "header": "Auth", "prompt": "Which auth method?", "multi_select": false, "allows_other": true,
                   "options": [["id": "oauth", "label": "OAuth", "detail": "Delegated"],
                               ["id": "keys", "label": "API keys", "preview": ["text": "KEY=...", "format": "monospace"]]]]],
        "state": ["kind": "pending"],
    ]

    @Test func aPendingPartMapsToTheModel() throws {
        let question = try #require(AgentQuestion(conversationPart: part, messageID: "msg_1", partIndex: 2))
        #expect(question.id == "msg_1#2")
        #expect(question.source == .init(harness: .chief, session: "sess_mux", permission: "perm_1", agentName: "Chief"))
        #expect(question.items[0].options[1].preview == .init(text: "KEY=...", format: .monospace))
        #expect(question.items[0].allowsOther)
        #expect(question.isPending)
    }

    @Test func anAnsweredPartCarriesTheStampedRespondent() throws {
        var answered = part
        if case .object(var object) = answered {
            object["state"] = ["kind": "answered", "answer": [
                "selections": ["q0": ["option_ids": ["keys"]]],
                "respondent": ["participant": "user_local", "display_name": "Lawrence's iPhone", "device": "Lawrence's iPhone", "remote": true],
                "answered_at": "2026-10-07T12:00:00.000Z",
            ]]
            answered = .object(object)
        }
        let question = try #require(AgentQuestion(conversationPart: answered, messageID: "msg_1", partIndex: 0))
        guard case .answered(let answer) = question.state else { Issue.record("not answered"); return }
        #expect(answer.selections["q0"]?.optionIDs == ["keys"])
        #expect(answer.respondent?.isRemote == true)
        #expect(answer.respondent?.device == "Lawrence's iPhone")
        #expect(answer.answeredAtMs == 1_791_374_400_000)
    }

    @Test func theOpAnswerIsSnakeCaseSelectionsOnly() throws {
        let answer = AgentQuestionAnswer(selections: ["q0": .init(optionIDs: ["keys"], other: "and SSO")],
                                         respondent: .init(participant: "forged"))
        let data = try answer.conversationAnswer.data()
        #expect(String(decoding: data, as: UTF8.self) == #"{"selections":{"q0":{"option_ids":["keys"],"other":"and SSO"}}}"#)
    }

    @Test func aPartWithoutItemsIsNotAQuestion() {
        #expect(AgentQuestion(conversationPart: ["type": "question", "session": "s", "items": []], messageID: "m", partIndex: 0) == nil)
    }
}

@Suite struct AgentQuestionAnsweringTests {
    @Test func anOwnerCommitsAValidAnswerOnceInOptionOrder() throws {
        let question = try AgentQuestionFixture(name: "pending-multi").question
        let answered = try question.answering(AgentQuestionAnswer(selections: ["q0": .init(optionIDs: ["Web", "macOS"])]),
                                              respondent: .init(participant: "user_local"), atMs: 5)
        guard case .answered(let answer) = answered.state else { Issue.record("not answered"); return }
        #expect(answer.selections["q0"]?.optionIDs == ["macOS", "Web"])
        #expect(answer.respondent?.participant == "user_local")
        #expect(throws: AgentQuestionAnswer.Problem.notPending) {
            try answered.answering(AgentQuestionAnswer(selections: ["q0": .init(optionIDs: ["iOS"])]), respondent: nil, atMs: nil)
        }
    }

    @Test func transcriptTextNumbersOptionsThenShowsTheAnswer() throws {
        let pending = try AgentQuestionFixture(name: "acp-interactive").question
        #expect(pending.transcriptText == "Continue with the migration on the staging branch?\n1. Proceed\n2. Dry run first\n3. Stop")
        let answered = try AgentQuestionFixture(name: "answered-collapsed").question
        #expect(answered.transcriptText == "Which auth method should the API use?\n✓ Passkeys")
    }
}
