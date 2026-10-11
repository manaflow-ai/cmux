public import Foundation

/// Unsent answers, per item: client view state (feed.md section 4), shared
/// by the variants so switching layouts keeps a half-written answer.
public nonisolated struct FeedDrafts: Sendable, Equatable {
    /// Choice answers by item, then by question id.
    public var choices: [String: [String: FeedChoiceSelection]] = [:]
    /// Free-text replies (questions, review comments) by item.
    public var replies: [String: String] = [:]
    /// The approve scope picked for an item (default: the first offered).
    public var scopes: [String: FeedApproveScope] = [:]

    public init() {}

    public func choice(_ item: String, _ question: String) -> FeedChoiceSelection {
        choices[item]?[question] ?? FeedChoiceSelection()
    }

    public mutating func toggle(_ item: String, question: FeedPrompt.ChoiceQuestion, option: String) {
        var selection = choice(item, question.id)
        selection.toggle(option, multi: question.multi)
        choices[item, default: [:]][question.id] = selection
    }

    public mutating func setOther(_ item: String, question: FeedPrompt.ChoiceQuestion, text: String) {
        var selection = choice(item, question.id)
        selection.other = text
        if !question.multi && !text.isEmpty { selection.selected = [] }
        choices[item, default: [:]][question.id] = selection
    }

    public mutating func clear(_ item: String) {
        choices[item] = nil
        replies[item] = nil
        scopes[item] = nil
    }
}
