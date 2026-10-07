import CmuxAgentQuestion
import CmuxHomeCore
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// The local owner's `question` part as a Home question, and a Home answer
/// as the owner's `question.answer` op (plans/cmux-next/agent-questions.md).
@Suite struct HomeQuestionMappingTests {
    @Test func aQuestionPartBecomesAHomeQuestionAddressedByMessageAndPart() throws {
        let json = #"""
        {"type":"question","harness":"chief","session":"sess_mux","permission":"perm_1","agent":"Chief",
         "items":[{"id":"q0","prompt":"Merge now?","options":[{"id":"yes","label":"Yes"},{"id":"no","label":"No"}],
                   "multi_select":false,"allows_other":false}],"state":{"kind":"pending"}}
        """#
        let part = try JSONDecoder().decode(ConversationPart.self, from: Data(json.utf8))
        guard case .question(let question) = HomeCoreMapping.part(part, messageID: "msg_9", index: 1) else {
            Issue.record("not a question"); return
        }
        #expect(question.id == "msg_9#1")
        #expect(question.source.permission == "perm_1")
        #expect(question.items[0].options.map(\.label) == ["Yes", "No"])
        #expect(!question.items[0].allowsOther)
    }

    @Test func anAnswerBecomesTheOwnersQuestionAnswerOp() throws {
        let op = HomeOp.answerQuestion(message: MessageID("msg_9"), conversation: ConversationID("conv_01"), partIndex: 1,
                                       answer: AgentQuestionAnswer(selections: ["q0": .init(optionIDs: ["yes"])]))
        let mapped = try #require(HomeCoreMapping.op(op, key: IdempotencyKey("cmk_a")))
        #expect(mapped.conversation == "conv_01")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let text = String(decoding: try encoder.encode(mapped.op), as: UTF8.self)
        #expect(text == #"{"answer":{"selections":{"q0":{"option_ids":["yes"]}}},"kind":"question.answer","message_id":"msg_9","part_index":1}"#)
    }
}
