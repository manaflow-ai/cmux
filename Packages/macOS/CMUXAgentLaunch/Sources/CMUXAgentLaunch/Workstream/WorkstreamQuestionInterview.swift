import Foundation

/// Pure projections over a workstream question prompt set.
///
/// Computes the answer-composition and plan-detection facts the Feed's
/// question UI needs, with no view, AppKit, or SwiftUI dependency. The
/// SwiftUI `QuestionActionArea` view owns the live `@State` selection and
/// free-text dictionaries plus the localized CTA labels; it constructs one
/// of these from the prompt set and passes its current selections and
/// free-text answers in as parameters so every fact is a deterministic
/// function of the prompts plus the current input.
public struct WorkstreamQuestionInterview: Sendable, Equatable {
    /// The questions the agent posed for this feed event.
    public let questions: [WorkstreamQuestionPrompt]
    /// Which agent posed the questions.
    public let source: WorkstreamSource
    /// Nearby conversation state, when available.
    public let context: WorkstreamContext?

    /// Selection id used for the per-question "Type something…" custom
    /// answer. Stored in a question's selection set when a free-text
    /// answer is active so the custom answer participates in
    /// multi/single selection exactly like a preset option.
    public static let customAnswerSelectionId = "__cmux_custom_answer__"

    public init(
        questions: [WorkstreamQuestionPrompt],
        source: WorkstreamSource,
        context: WorkstreamContext?
    ) {
        self.questions = questions
        self.source = source
        self.context = context
    }

    /// One answer string per question: the user's free-form text if
    /// they typed any, otherwise the labels of the selected options
    /// joined by ", ". Questions with no answer are omitted entirely
    /// so the agent doesn't see "question 2: <empty>".
    ///
    /// - Parameters:
    ///   - selections: per-question selected option ids, keyed by question id.
    ///   - freeTexts: per-question custom free-form answers, keyed by question id.
    public func composedAnswers(
        selections: [String: Set<String>],
        freeTexts: [String: String]
    ) -> [String] {
        var out: [String] = []
        for q in questions {
            let freeText = (freeTexts[q.id] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let ids = selections[q.id] ?? []
            if !freeText.isEmpty, ids.contains(Self.customAnswerSelectionId) {
                out.append(freeText)
                continue
            }
            guard !ids.isEmpty else { continue }
            let labels = q.options
                .filter { ids.contains($0.id) }
                .map(\.label)
            if !labels.isEmpty {
                out.append(labels.joined(separator: ", "))
            }
        }
        return out
    }

    /// Whether any question has a usable answer given the current input.
    public func hasAnyAnswer(
        selections: [String: Set<String>],
        freeTexts: [String: String]
    ) -> Bool {
        !composedAnswers(selections: selections, freeTexts: freeTexts).isEmpty
    }

    /// Whether the prompt set can be submitted with no answer, which is
    /// allowed only when every question is option-less (free-form only).
    public var canSubmitEmptyAnswer: Bool {
        !questions.isEmpty && questions.allSatisfy { $0.options.isEmpty }
    }

    /// Long-form: single question whose options carry descriptions
    /// (e.g. Claude's AskUserQuestion with `header` + per-option
    /// detail). Multi-option list with a bigger rich-text card per
    /// option, click-to-select.
    public var shouldRenderLongForm: Bool {
        guard questions.count == 1, let q = questions.first else { return false }
        return q.options.contains { $0.description?.isEmpty == false }
    }

    /// Whether this prompt set is a Claude plan-mode interview, which
    /// gets the extra "Skip + plan immediately" CTA.
    public var isPlanAskUserQuestion: Bool {
        guard source == .claude else { return false }
        if let mode = context?.permissionMode {
            return mode.caseInsensitiveCompare("plan") == .orderedSame
        }
        return questionTextLooksLikePlanInterview
    }

    /// Heuristic plan-mode detection from the question and context text,
    /// used when the agent did not record an explicit permission mode.
    public var questionTextLooksLikePlanInterview: Bool {
        let fragments: [String?] = questions.flatMap { q in
            let questionFragments: [String?] = [q.header, q.prompt]
            let optionFragments: [String?] = q.options.flatMap { option in
                [option.label, option.description]
            }
            return questionFragments + optionFragments
        }
        let text = ([context?.lastUserMessage, context?.assistantPreamble] + fragments)
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return text.contains("plan mode")
            || text.contains("make a plan")
            || text.contains("plan-only")
            || text.contains("plan immediately")
    }
}
