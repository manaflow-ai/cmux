import CmuxAgentQuestion
import Foundation
import Testing

/// A client that did not answer a question (another device, or a chat opened on its
/// history) reads the answer back from what the owner recorded: `recordedAnswer` is the
/// inverse of `reply(_:)` for every harness shape. The iPhone used to show "You answered"
/// over an empty bubble for every answered question it read from acpmux.
@Suite struct AgentQuestionRecordedAnswerTests {
    @Test(arguments: ["pending-single", "pending-multi", "pending-4-questions", "codex-user-input", "acp-interactive", "chief-asks"])
    func aRecordedAnswerReadsBackAsTheAnswerSent(_ name: String) throws {
        var question = try #require(try AgentQuestionFixture(name: name).mapped())
        question.state = .pending
        // Each item's last option, plus Other text where the item takes it (not ACP).
        var selections: [String: AgentQuestionAnswer.Selection] = [:]
        for item in question.items {
            guard let last = item.options.last else {
                // A free-text item: its answer is the Other text.
                selections[item.id] = .init(other: "free text")
                continue
            }
            let other = item.allowsOther && item.multiSelect ? "also this" : nil
            selections[item.id] = .init(optionIDs: [last.id], other: other)
        }
        let answer = AgentQuestionAnswer(selections: selections)
        let reply = try question.reply(answer)
        let read = question.recordedAnswer(reply.answers, optionId: reply.optionId)
        #expect(read == answer, "\(name)")
    }

    /// Other text alone, on a single-select item: the value matches no label.
    @Test func otherTextReadsBackAsOther() throws {
        var question = try #require(try AgentQuestionFixture(name: "pending-single").mapped())
        question.state = .pending
        let item = try #require(question.items.first)
        try #require(item.allowsOther)
        let answer = AgentQuestionAnswer(selections: [item.id: .init(other: "staging, then prod")])
        let reply = try question.reply(answer)
        #expect(question.recordedAnswer(reply.answers, optionId: reply.optionId) == answer)
    }

    /// Nothing recorded (a decline, a cancel): no selections.
    @Test func noAnswersMeansNoSelections() throws {
        let question = try #require(try AgentQuestionFixture(name: "pending-single").mapped())
        #expect(question.recordedAnswer(nil, optionId: nil).selections.isEmpty)
    }

    /// A multi-select label that holds ", " (Claude joins choices with ", ") reads back whole.
    @Test func aLabelWithACommaReadsBackWhole() throws {
        var question = try #require(try AgentQuestionFixture(name: "pending-multi").mapped())
        question.state = .pending
        var item = try #require(question.items.first)
        try #require(item.multiSelect && item.options.count >= 2)
        item.options[0].label = "Red, Blue"
        question.items[0] = item
        let answer = AgentQuestionAnswer(selections: [item.id: .init(optionIDs: [item.options[0].id, item.options[1].id], other: "teal, too")])
        let reply = try question.reply(answer)
        #expect(question.recordedAnswer(reply.answers, optionId: reply.optionId) == answer)
    }
}
