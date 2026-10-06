#if os(iOS)
import CmuxMobileShellModel
import Foundation

/// Builds the ordered answer payload submitted for an agent question event.
struct AgentFeedQuestionAnswerBuilder: Sendable {
    /// The editable answer state for one question.
    struct Draft: Equatable, Sendable {
        let selectedOptionIDs: Set<String>
        let customText: String

        init(selectedOptionIDs: Set<String> = [], customText: String = "") {
            self.selectedOptionIDs = selectedOptionIDs
            self.customText = customText
        }

        var trimmedCustomText: String {
            customText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var hasAnswer: Bool {
            !trimmedCustomText.isEmpty || !selectedOptionIDs.isEmpty
        }
    }

    /// Returns one answer per question when every question has an answer.
    func answers(
        for questions: [MobileAgentFeedQuestion],
        drafts: [String: Draft]
    ) -> [String]? {
        let answers = questions.compactMap { question in
            answer(for: question, draft: drafts[question.id] ?? Draft())
        }
        return answers.count == questions.count ? answers : nil
    }

    /// Converts one draft to the labels the Mac-side agent expects.
    func answer(for question: MobileAgentFeedQuestion, draft: Draft) -> String? {
        if !draft.trimmedCustomText.isEmpty {
            return draft.trimmedCustomText
        }

        let selectedLabels = question.options.compactMap { option in
            draft.selectedOptionIDs.contains(option.id) ? option.label : nil
        }
        guard !selectedLabels.isEmpty else { return nil }
        return selectedLabels.joined(separator: ", ")
    }
}
#endif
