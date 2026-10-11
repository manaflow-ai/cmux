import Foundation

/// Why a choice answer is not sendable yet.
public nonisolated enum FeedChoiceIssue: Sendable, Equatable, Hashable {
    /// No option and no "Other" text for this question.
    case unanswered(question: String)
    /// A single-select question got more than one answer.
    case tooMany(question: String)
    case unknownOption(question: String, option: String)
    case unknownQuestion(String)
    /// "Other" text on a question that does not allow it.
    case otherNotAllowed(question: String)
}

/// The client-side check of a `choice` answer before it is sent (the owner
/// checks again against the kind's schema). Pure.
public nonisolated enum FeedChoiceValidation {
    public static func issues(_ answers: [String: FeedChoiceSelection], for prompt: FeedPrompt.Choice) -> [FeedChoiceIssue] {
        var issues: [FeedChoiceIssue] = []
        let known = Set(prompt.questions.map(\.id))
        for id in answers.keys.sorted() where !known.contains(id) {
            issues.append(.unknownQuestion(id))
        }
        for question in prompt.questions {
            let selection = answers[question.id] ?? FeedChoiceSelection()
            let other = selection.other?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let options = Set(question.options.map(\.id))
            for option in selection.selected where !options.contains(option) {
                issues.append(.unknownOption(question: question.id, option: option))
            }
            if !other.isEmpty && !question.allowOther {
                issues.append(.otherNotAllowed(question: question.id))
            }
            let count = Set(selection.selected).count + (other.isEmpty ? 0 : 1)
            if count == 0 {
                issues.append(.unanswered(question: question.id))
            } else if count > 1 && !question.multi {
                issues.append(.tooMany(question: question.id))
            }
        }
        return issues
    }

    /// The answer with blank "Other" text removed, or nil while it has issues.
    public static func normalized(_ answers: [String: FeedChoiceSelection], for prompt: FeedPrompt.Choice) -> [String: FeedChoiceSelection]? {
        guard issues(answers, for: prompt).isEmpty else { return nil }
        var out: [String: FeedChoiceSelection] = [:]
        for question in prompt.questions {
            var selection = answers[question.id] ?? FeedChoiceSelection()
            let other = selection.other?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            selection.other = other.isEmpty ? nil : other
            out[question.id] = selection
        }
        return out
    }
}
