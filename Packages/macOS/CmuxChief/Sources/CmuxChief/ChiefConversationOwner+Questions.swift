public import CmuxAgentQuestion
public import CmuxHomeCore
import Foundation

// Question cards answered without Home (DEBUG `chief.answer`): the same `HomeOp.answerQuestion`
// the card sends, so the card closes and the Chief hears the answer as its next turn.
extension ChiefConversationOwner {
    /// A question card that still waits for its answer (``pendingQuestion(in:message:)``).
    public struct PendingQuestion: Sendable, Equatable {
        /// The card's message.
        public var message: MessageID
        /// The question part's index in that message.
        public var part: Int
        /// The question.
        public var question: AgentQuestion
    }

    /// The question card `chief.answer` answers in `conversation`.
    ///
    /// - Parameters:
    ///   - conversation: The conversation.
    ///   - message: Only this message's card (its id); nil: the newest card still waiting.
    /// - Returns: The card, nil when none waits (an answered or cancelled card does not count).
    public func pendingQuestion(in conversation: ConversationID, message: String? = nil) -> PendingQuestion? {
        guard let state = conversations[conversation] else { return nil }
        for candidate in state.messages.reversed() where message == nil || candidate.id.rawValue == message {
            for (index, part) in candidate.parts.enumerated().reversed() {
                if case .question(let question) = part, question.isPending {
                    return PendingQuestion(message: candidate.id, part: index, question: question)
                }
            }
        }
        return nil
    }

    /// Answers a waiting question card as its Submit button does (``submit(_:)`` with
    /// `HomeOp.answerQuestion`).
    ///
    /// - Parameters:
    ///   - card: The card (``pendingQuestion(in:message:)``).
    ///   - conversation: Its conversation.
    ///   - choices: Option labels or ids (``ChiefQuestionAnswer/answer(for:choices:text:)``).
    ///   - text: Free text for an item's Other field.
    /// - Returns: The answer's summary lines, as the Chief reads them ("Machine: 4 GB").
    /// - Throws: ``ChiefQuestionAnswer/Problem`` when the choices do not answer the card,
    ///   ``HomeRejection`` when the owner refuses it (`question_closed`).
    @discardableResult
    public func answerQuestion(_ card: PendingQuestion, in conversation: ConversationID, choices: [String],
                               text: String?) throws -> [String] {
        let answer = try ChiefQuestionAnswer.answer(for: card.question, choices: choices, text: text)
        try submit(HomeIntent(op: .answerQuestion(message: card.message, conversation: conversation, partIndex: card.part,
                                                  answer: answer)))
        return card.question.summaryLines(answer)
    }
}

/// An answer to a question card from words instead of clicks (`cmux chief answer --choice "4 GB"`).
///
/// Each choice names one option, by its label or id (case-insensitive), in the first item that
/// has it and can still take it. `text` fills the Other field of the first item still without
/// a choice (else of a multi-choice item). A single-choice item nothing names keeps the card's
/// preselection, its first option (the Chief puts its recommendation first), exactly as pressing
/// the card's Submit right away would. Pure: tests pin it.
public enum ChiefQuestionAnswer {
    /// Why words do not answer a card.
    public enum Problem: Error, Equatable, Sendable {
        /// No item of the card has an option with this label or id (or every item that has it is answered).
        case unknownChoice(String)
        /// No item of the card takes free text.
        case otherNotAllowed
        /// The answer is still incomplete or contradicts the card (``AgentQuestionAnswer/problems(for:)``).
        case invalid([AgentQuestionAnswer.Problem])
    }

    /// The card's answer for `choices` and `text`.
    ///
    /// - Throws: ``Problem``.
    public static func answer(for question: AgentQuestion, choices: [String], text: String?) throws -> AgentQuestionAnswer {
        var chosen: [String: [String]] = [:]
        for choice in choices {
            let matches = question.items.compactMap { item -> (item: AgentQuestion.Item, option: String)? in
                let option = item.options.first { $0.label.caseInsensitiveCompare(choice) == .orderedSame }
                    ?? item.options.first { $0.id.caseInsensitiveCompare(choice) == .orderedSame }
                return option.map { (item: item, option: $0.id) }
            }
            // The first item that can still take it: a single-choice item takes one option.
            guard let match = matches.first(where: { $0.item.multiSelect || chosen[$0.item.id] == nil }) ?? matches.first else {
                throw Problem.unknownChoice(choice)
            }
            if !(chosen[match.item.id] ?? []).contains(match.option) { chosen[match.item.id, default: []].append(match.option) }
        }
        var other: [String: String] = [:]
        if let text {
            guard let item = question.items.first(where: { $0.allowsOther && chosen[$0.id] == nil })
                ?? question.items.first(where: { $0.allowsOther && $0.multiSelect }) else { throw Problem.otherNotAllowed }
            other[item.id] = text
        }
        var selections: [String: AgentQuestionAnswer.Selection] = [:]
        for item in question.items {
            var ids = chosen[item.id] ?? []
            if ids.isEmpty, other[item.id] == nil, !item.multiSelect, let first = item.options.first { ids = [first.id] }
            selections[item.id] = AgentQuestionAnswer.Selection(optionIDs: ids, other: other[item.id])
        }
        let answer = AgentQuestionAnswer(selections: selections)
        let problems = answer.problems(for: question)
        guard problems.isEmpty else { throw Problem.invalid(problems) }
        return answer
    }
}
