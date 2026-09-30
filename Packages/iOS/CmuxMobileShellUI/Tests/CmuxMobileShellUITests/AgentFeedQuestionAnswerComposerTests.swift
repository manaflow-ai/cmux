#if os(iOS)
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite struct AgentFeedQuestionAnswerComposerTests {
    @Test func answersUseHumanLabelsInQuestionOrder() {
        let first = question(
            id: "first",
            options: [
                .init(id: "a", label: "Alpha"),
                .init(id: "b", label: "Beta"),
            ]
        )
        let second = question(
            id: "second",
            options: [
                .init(id: "c", label: "Gamma"),
                .init(id: "d", label: "Delta"),
            ]
        )

        let answers = AgentFeedQuestionAnswerDraft.answers(
            for: [first, second],
            drafts: [
                "first": .init(selectedOptionIDs: ["b"], customText: ""),
                "second": .init(selectedOptionIDs: ["d"], customText: ""),
            ]
        )

        #expect(answers == ["Beta", "Delta"])
    }

    @Test func multiSelectPreservesDisplayedOptionOrder() {
        let q = question(
            id: "q",
            options: [
                .init(id: "a", label: "Alpha"),
                .init(id: "b", label: "Beta"),
                .init(id: "c", label: "Gamma"),
            ],
            multiSelect: true
        )

        let answer = AgentFeedQuestionAnswerDraft.answer(
            for: q,
            draft: .init(selectedOptionIDs: ["c", "a"], customText: "")
        )

        #expect(answer == "Alpha, Gamma")
    }

    @Test func customAnswerReplacesOptionSelection() {
        let q = question(id: "q", options: [.init(id: "a", label: "Alpha")])

        let answer = AgentFeedQuestionAnswerDraft.answer(
            for: q,
            draft: .init(selectedOptionIDs: ["a"], customText: "  A custom answer  ")
        )

        #expect(answer == "A custom answer")
    }

    @Test func answersStayUnavailableUntilEveryQuestionHasAnAnswer() {
        let first = question(id: "first", options: [.init(id: "a", label: "Alpha")])
        let second = question(id: "second", options: [.init(id: "b", label: "Beta")])

        let answers = AgentFeedQuestionAnswerDraft.answers(
            for: [first, second],
            drafts: ["first": .init(selectedOptionIDs: ["a"], customText: "")]
        )

        #expect(answers == nil)
    }

    private func question(
        id: String,
        options: [MobileAgentFeedQuestionOption],
        multiSelect: Bool = false
    ) -> MobileAgentFeedQuestion {
        MobileAgentFeedQuestion(
            id: id,
            prompt: "Prompt (id)",
            multiSelect: multiSelect,
            options: options
        )
    }
}
#endif
