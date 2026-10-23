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
    ///   - choices: Option labels or ids (``ChiefQuestionAnswer/answer(for:)``).
    ///   - text: Free text for an item's Other field.
    /// - Returns: The answer's summary lines, as the Chief reads them ("Machine: 4 GB").
    /// - Throws: ``ChiefQuestionAnswer/Problem`` when the choices do not answer the card,
    ///   ``HomeRejection`` when the owner refuses it (`question_closed`).
    @discardableResult
    public func answerQuestion(_ card: PendingQuestion, in conversation: ConversationID, choices: [String],
                               text: String?) throws -> [String] {
        let answer = try ChiefQuestionAnswer(choices: choices, text: text).answer(for: card.question)
        try submit(HomeIntent(op: .answerQuestion(message: card.message, conversation: conversation, partIndex: card.part,
                                                  answer: answer)))
        return card.question.summaryLines(answer)
    }

    /// The user wrote instead of pressing the card's button: the newest waiting card closes, so
    /// no live "Create" stays under the conversation. Text that names an option of every item
    /// ("4 GB", "Machine: 4 GB") answers it as the button would (its receipt "Machine: 4 GB");
    /// other text cancels it (the receipt says the answer came in the chat). The message itself
    /// still goes to the Chief as the user's turn, unchanged.
    ///
    /// - Returns: The card's state after the change, nil when no card waited.
    @discardableResult
    func settlePendingQuestion(byChat text: String, in conversation: ConversationID) -> AgentQuestion? {
        guard let card = pendingQuestion(in: conversation) else { return nil }
        let respondent = AgentQuestionAnswer.Respondent(participant: me.id.rawValue, displayName: me.displayName)
        let atMs = Int64(now().timeIntervalSince1970 * 1000)
        var next = card.question
        if let answer = ChiefQuestionAnswer.fromChat(text, question: card.question),
           let answered = try? card.question.answering(answer, respondent: respondent, atMs: atMs) {
            next = answered
        } else {
            next.state = .cancelled
        }
        let settled = next
        _ = try? updateMessage(card.message, in: conversation) { message in
            guard message.parts.indices.contains(card.part), case .question(let question) = message.parts[card.part],
                  question.isPending else { return }
            message.parts[card.part] = .question(settled)
        }
        return settled
    }
}

/// An answer to a question card from words instead of clicks (`cmux chief answer --choice "4 GB"`).
///
/// Each choice names one option, by its label or id (case-insensitive), in the first item that
/// has it and can still take it. `text` fills the Other field of the first item still without
/// a choice (else of a multi-choice item). A single-choice item nothing names keeps the card's
/// preselection, its first option (the Chief puts its recommendation first), exactly as pressing
/// the card's Submit right away would. Pure: tests pin it.
public struct ChiefQuestionAnswer: Sendable {
    /// Mobile Chief qualifies an option id with its item id using this
    /// separator. Bare ids remain accepted for the CLI and older clients.
    public static let qualifiedChoiceSeparator = "\u{001F}"
    /// Option labels or ids, in the order given.
    public var choices: [String]
    /// Free text for an Other field, if any.
    public var text: String?

    public init(choices: [String], text: String? = nil) {
        self.choices = choices
        self.text = text
    }

    /// Why words do not answer a card.
    public enum Problem: Error, Equatable, Sendable {
        /// No item of the card has an option with this label or id (or every item that has it is answered).
        case unknownChoice(String)
        /// No item of the card takes free text.
        case otherNotAllowed
        /// The answer is still incomplete or contradicts the card (``AgentQuestionAnswer/problems(for:)``).
        case invalid([AgentQuestionAnswer.Problem])
    }

    /// The answer a chat message gives `question`, nil unless it names an option of every item.
    ///
    /// Each line (and the whole text) is tried as an option label or id, with a leading
    /// "<header or prompt>:" and trailing punctuation dropped, so "4 GB", "4 gb." and the owner's
    /// own "My answer to your question:\nMachine: 4 GB" all answer a one-item "Machine" card.
    public static func fromChat(_ text: String, question: AgentQuestion) -> AgentQuestionAnswer? {
        let labels = question.items.flatMap { item in [item.header, item.prompt].compactMap { $0 } }
        var candidates: [String] = []
        for raw in [text] + text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let colon = line.firstIndex(of: ":"),
               labels.contains(where: { $0.caseInsensitiveCompare(line[..<colon].trimmingCharacters(in: .whitespaces)) == .orderedSame }) {
                line = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: ".!").union(.whitespaces))
            if !line.isEmpty, !candidates.contains(line) { candidates.append(line) }
        }
        var choices: [String] = []
        var named = Set<String>()
        for candidate in candidates {
            for item in question.items {
                guard item.options.contains(where: {
                    $0.label.caseInsensitiveCompare(candidate) == .orderedSame || $0.id.caseInsensitiveCompare(candidate) == .orderedSame
                }) else { continue }
                choices.append(candidate)
                named.insert(item.id)
                break
            }
        }
        guard !choices.isEmpty, question.items.allSatisfy({ named.contains($0.id) }) else { return nil }
        return try? ChiefQuestionAnswer(choices: choices).answer(for: question)
    }

    /// The card's answer for `choices` and `text`.
    ///
    /// - Throws: ``Problem``.
    public func answer(for question: AgentQuestion) throws -> AgentQuestionAnswer {
        var chosen: [String: [String]] = [:]
        for choice in choices {
            let qualified = choice.components(separatedBy: Self.qualifiedChoiceSeparator)
            let requestedItemID = qualified.count == 2 ? String(qualified[0]) : nil
            let requestedChoice = qualified.count == 2 ? String(qualified[1]) : choice
            let matches = question.items.compactMap { item -> (item: AgentQuestion.Item, option: String)? in
                if let requestedItemID, item.id != requestedItemID { return nil }
                let option = item.options.first { $0.label.caseInsensitiveCompare(requestedChoice) == .orderedSame }
                    ?? item.options.first { $0.id.caseInsensitiveCompare(requestedChoice) == .orderedSame }
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
