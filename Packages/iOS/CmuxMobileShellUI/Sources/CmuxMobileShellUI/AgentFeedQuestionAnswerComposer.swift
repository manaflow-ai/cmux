#if os(iOS)
import CmuxMobileShellModel

/// The local draft for one question in a multi-question AskUserQuestion round.
/// Option ids stay local to the picker; the submitted answer is the human
/// readable label Claude expects in its `answers` map.
struct AgentFeedQuestionAnswerDraft: Equatable, Sendable {
    var selectedOptionIDs: Set<String> = []
    var customText = ""

    var hasAnswer: Bool {
        !selectedOptionIDs.isEmpty || !customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// Composes one question's answer, preserving the option order shown to
    /// the user and letting a custom answer replace preset options.
    static func answer(
        for question: MobileAgentFeedQuestion,
        draft: AgentFeedQuestionAnswerDraft
    ) -> String? {
        let custom = draft.customText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            return custom
        }
        let labels = question.options
            .filter { draft.selectedOptionIDs.contains($0.id) }
            .map(\.label)
        guard !labels.isEmpty else { return nil }
        return labels.joined(separator: ", ")
    }

    /// Produces one ordered answer per question. The Feed only submits after
    /// every page has an answer, so the resulting array maps exactly to
    /// Claude's question order.
    static func answers(
        for questions: [MobileAgentFeedQuestion],
        drafts: [String: AgentFeedQuestionAnswerDraft]
    ) -> [String]? {
        let answers = questions.compactMap { question in
            answer(for: question, draft: drafts[question.id] ?? AgentFeedQuestionAnswerDraft())
        }
        guard answers.count == questions.count else { return nil }
        return answers
    }
}
#endif
