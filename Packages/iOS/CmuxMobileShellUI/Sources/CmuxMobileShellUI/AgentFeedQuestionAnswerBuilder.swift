#if os(iOS)
import CmuxMobileShellModel
import Foundation

/// Builds the ordered answer payload submitted for an agent question event.
struct AgentFeedQuestionAnswerBuilder: Sendable {
    /// The editable answer state for one question.
    struct Draft: Equatable, Sendable {
        private(set) var selectedOptionIDs: Set<String>
        private(set) var isCustomAnswerSelected: Bool
        private var storedCustomText: String

        init(selectedOptionIDs: Set<String> = [], customText: String = "") {
            let usesCustomAnswer = !customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            self.selectedOptionIDs = usesCustomAnswer ? [] : selectedOptionIDs
            self.isCustomAnswerSelected = usesCustomAnswer
            self.storedCustomText = customText
        }

        var customText: String {
            get { storedCustomText }
            set {
                guard storedCustomText != newValue else { return }
                storedCustomText = newValue
                selectCustomAnswer()
            }
        }

        /// Focus and the selection button choose the same answer mode, even before typing.
        mutating func selectCustomAnswer() {
            isCustomAnswerSelected = true
            selectedOptionIDs.removeAll()
        }

        mutating func toggleOption(_ optionID: String, multiSelect: Bool) {
            isCustomAnswerSelected = false
            if multiSelect {
                if selectedOptionIDs.contains(optionID) {
                    selectedOptionIDs.remove(optionID)
                } else {
                    selectedOptionIDs.insert(optionID)
                }
            } else {
                selectedOptionIDs = [optionID]
            }
        }

        var trimmedCustomText: String {
            customText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var hasAnswer: Bool {
            isCustomAnswerSelected ? !trimmedCustomText.isEmpty : !selectedOptionIDs.isEmpty
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
        if draft.isCustomAnswerSelected {
            return draft.trimmedCustomText.isEmpty ? nil : draft.trimmedCustomText
        }

        let selectedLabels = question.options.compactMap { option in
            draft.selectedOptionIDs.contains(option.id) ? option.label : nil
        }
        guard !selectedLabels.isEmpty else { return nil }
        return selectedLabels.joined(separator: ", ")
    }
}
#endif
