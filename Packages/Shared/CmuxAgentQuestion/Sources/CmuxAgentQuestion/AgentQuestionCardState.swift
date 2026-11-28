public import Foundation

/// The interaction state of one question card: which item is shown, which
/// row is highlighted, what is chosen and the Other drafts. Pure: every
/// renderer (the Mac card, the agent tab, tests) drives the same reducer, so
/// keyboard behavior is identical everywhere.
///
/// Rows of an item are its options, then one "Other" row when the item
/// allows free text. Only `send(_:)` with a person's key or click produces
/// `.submit`; nothing answers on a timer or by default.
public struct AgentQuestionCardState: Hashable, Sendable {
    public private(set) var question: AgentQuestion
    /// Index of the item on screen (a card with several items shows one at a time).
    public private(set) var activeItem = 0
    /// Highlighted row per item id.
    public private(set) var highlighted: [String: Int] = [:]
    public private(set) var chosen: [String: Set<String>] = [:]
    public private(set) var otherDrafts: [String: String] = [:]
    /// True while the Other text field of the active item has the keyboard.
    public private(set) var editingOther = false

    public init(question: AgentQuestion) {
        self.question = question
    }

    public enum Input: Hashable, Sendable {
        /// 1-9: the row at that position.
        case number(Int)
        case up, down
        /// Previous or next item.
        case previousItem, nextItem
        /// Enter: choose the highlighted row, then advance or submit.
        case confirm
        /// Space: toggle the highlighted row (multi-select) or choose it.
        case toggle
        /// A click on a row.
        case click(row: Int)
        /// Text typed into the active item's Other field.
        case otherText(String)
        /// Escape.
        case escape
        /// The explicit Submit button.
        case submit
    }

    public enum Effect: Hashable, Sendable {
        case none
        /// Send this answer (built from a person's gesture).
        case submit(AgentQuestionAnswer)
        /// The Other field should take the keyboard.
        case beginOtherEditing
        /// Give the keyboard back to the composer.
        case resign
    }

    public var item: AgentQuestion.Item { question.items[activeItem] }

    public func rowCount(_ item: AgentQuestion.Item) -> Int { item.options.count + (item.allowsOther ? 1 : 0) }

    public func isOtherRow(_ row: Int, in item: AgentQuestion.Item) -> Bool { item.allowsOther && row == item.options.count }

    public func highlightedRow(_ item: AgentQuestion.Item) -> Int { highlighted[item.id] ?? 0 }

    public func isChosen(_ option: AgentQuestion.Option, in item: AgentQuestion.Item) -> Bool {
        chosen[item.id]?.contains(option.id) == true
    }

    /// The selection of every item so far.
    public var answer: AgentQuestionAnswer {
        var selections: [String: AgentQuestionAnswer.Selection] = [:]
        for item in question.items {
            let ids = item.options.map(\.id).filter { chosen[item.id]?.contains($0) == true }
            selections[item.id] = AgentQuestionAnswer.Selection(optionIDs: ids, other: otherDrafts[item.id])
        }
        return AgentQuestionAnswer(selections: selections)
    }

    public var canSubmit: Bool { question.isPending && answer.problems(for: question).isEmpty }

    /// Replaces the question (for example when the owner's answered state
    /// arrives) and keeps the local choices for a still-pending ask.
    public mutating func update(_ question: AgentQuestion) {
        self.question = question
        activeItem = min(activeItem, max(question.items.count - 1, 0))
        if !question.isPending { editingOther = false }
    }

    public mutating func send(_ input: Input) -> Effect {
        guard question.isPending, !question.items.isEmpty else { return input == .escape ? .resign : .none }
        let item = item
        let rows = rowCount(item)
        switch input {
        case .number(let number):
            guard (1...rows).contains(number) else { return .none }
            highlighted[item.id] = number - 1
            return choose(row: number - 1, in: item, advance: !item.multiSelect)
        case .up:
            highlighted[item.id] = max(highlightedRow(item) - 1, 0)
        case .down:
            highlighted[item.id] = min(highlightedRow(item) + 1, rows - 1)
        case .previousItem:
            editingOther = false
            activeItem = max(activeItem - 1, 0)
        case .nextItem:
            editingOther = false
            activeItem = min(activeItem + 1, question.items.count - 1)
        case .toggle:
            return choose(row: highlightedRow(item), in: item, advance: false)
        case .click(let row):
            guard (0..<rows).contains(row) else { return .none }
            highlighted[item.id] = row
            return choose(row: row, in: item, advance: !item.multiSelect)
        case .confirm:
            if editingOther {
                editingOther = false
                return advance()
            }
            // Multi-select: Enter ends this item's choices (Space toggles).
            if item.multiSelect { return advance() }
            return choose(row: highlightedRow(item), in: item, advance: true)
        case .otherText(let text):
            guard item.allowsOther else { return .none }
            otherDrafts[item.id] = text
            if !item.multiSelect, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chosen[item.id] = [] }
        case .escape:
            if editingOther {
                editingOther = false
                return .none
            }
            return .resign
        case .submit:
            return canSubmit ? .submit(answer) : .none
        }
        return .none
    }

    private mutating func choose(row: Int, in item: AgentQuestion.Item, advance shouldAdvance: Bool) -> Effect {
        if isOtherRow(row, in: item) {
            editingOther = true
            if !item.multiSelect { chosen[item.id] = [] }
            return .beginOtherEditing
        }
        let option = item.options[row].id
        if item.multiSelect {
            chosen[item.id, default: []].formSymmetricDifference([option])
        } else {
            chosen[item.id] = [option]
            otherDrafts[item.id] = nil
        }
        return shouldAdvance ? advance() : .none
    }

    /// Moves to the next unanswered item, or submits when every item is answered.
    private mutating func advance() -> Effect {
        let answer = answer
        if let next = question.items.indices.first(where: { $0 > activeItem && answer.selections[question.items[$0].id]?.isEmpty != false })
            ?? question.items.indices.first(where: { answer.selections[question.items[$0].id]?.isEmpty != false })
        {
            if next != activeItem { activeItem = next }
            return .none
        }
        return canSubmit ? .submit(answer) : .none
    }
}
