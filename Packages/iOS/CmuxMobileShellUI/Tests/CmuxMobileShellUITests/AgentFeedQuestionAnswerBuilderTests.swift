#if os(iOS)
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite struct AgentFeedQuestionAnswerBuilderTests {
    private let builder = AgentFeedQuestionAnswerBuilder()

    @Test func answersKeepQuestionAndOptionOrder() {
        let questions = [
            question(id: "first", options: [
                .init(id: "a", label: "Alpha"),
                .init(id: "b", label: "Beta"),
            ]),
            question(id: "second", options: [
                .init(id: "c", label: "Gamma"),
                .init(id: "d", label: "Delta"),
            ]),
        ]

        let answers = builder.answers(for: questions, drafts: [
            "first": .init(selectedOptionIDs: ["b"]),
            "second": .init(selectedOptionIDs: ["d"]),
        ])

        #expect(answers == ["Beta", "Delta"])
    }

    @Test func multiSelectUsesDisplayedOptionOrder() {
        let question = question(
            id: "q",
            options: [
                .init(id: "a", label: "Alpha"),
                .init(id: "b", label: "Beta"),
                .init(id: "c", label: "Gamma"),
            ],
            multiSelect: true
        )

        #expect(builder.answer(
            for: question,
            draft: .init(selectedOptionIDs: ["c", "a"])
        ) == "Alpha, Gamma")
    }

    @Test func customTextTakesPrecedenceAndTrimsWhitespace() {
        let question = question(id: "q", options: [.init(id: "a", label: "Alpha")])

        #expect(builder.answer(
            for: question,
            draft: .init(selectedOptionIDs: ["a"], customText: "  A custom answer  ")
        ) == "A custom answer")
    }

    @Test func incompleteDraftsCannotSubmit() {
        let questions = [
            question(id: "first", options: [.init(id: "a", label: "Alpha")]),
            question(id: "second", options: [.init(id: "b", label: "Beta")]),
        ]

        #expect(builder.answers(for: questions, drafts: [
            "first": .init(selectedOptionIDs: ["a"]),
        ]) == nil)
    }

    @Test func selectingEmptyCustomAnswerClearsChoicesAndBlocksSubmission() {
        let question = question(id: "q", options: [.init(id: "a", label: "Alpha")])
        var draft = AgentFeedQuestionAnswerBuilder.Draft(selectedOptionIDs: ["a"])

        draft.selectCustomAnswer()

        #expect(draft.isCustomAnswerSelected)
        #expect(draft.selectedOptionIDs.isEmpty)
        #expect(!draft.hasAnswer)
        #expect(builder.answers(for: [question], drafts: [question.id: draft]) == nil)
    }

    @Test func switchingToAnOptionPreservesCustomTextWithoutSubmittingIt() {
        let question = question(id: "q", options: [.init(id: "a", label: "Alpha")])
        var draft = AgentFeedQuestionAnswerBuilder.Draft(customText: "My draft")

        draft.toggleOption("a", multiSelect: false)

        #expect(!draft.isCustomAnswerSelected)
        #expect(draft.customText == "My draft")
        #expect(builder.answer(for: question, draft: draft) == "Alpha")

        draft.selectCustomAnswer()

        #expect(draft.selectedOptionIDs.isEmpty)
        #expect(builder.answer(for: question, draft: draft) == "My draft")
    }

    @Test func editingCustomTextSelectsItAndRejectsWhitespaceOnlyAnswers() {
        let question = question(id: "q", options: [.init(id: "a", label: "Alpha")])
        var draft = AgentFeedQuestionAnswerBuilder.Draft(selectedOptionIDs: ["a"])

        draft.customText = "  Typed answer  "

        #expect(draft.isCustomAnswerSelected)
        #expect(draft.selectedOptionIDs.isEmpty)
        #expect(draft.hasAnswer)
        #expect(builder.answer(for: question, draft: draft) == "Typed answer")

        draft.customText = " \n "

        #expect(draft.isCustomAnswerSelected)
        #expect(!draft.hasAnswer)
        #expect(builder.answer(for: question, draft: draft) == nil)
    }

    @Test(arguments: [false, true])
    func committingUnchangedCustomTextKeepsTheSelectedPreset(multiSelect: Bool) {
        let question = question(id: "q", options: [.init(id: "a", label: "Alpha")], multiSelect: multiSelect)
        var draft = AgentFeedQuestionAnswerBuilder.Draft(customText: "Saved draft")
        let committedText = draft.customText

        draft.toggleOption("a", multiSelect: multiSelect)
        // A text field can commit its current value again when it loses focus.
        draft.customText = committedText

        #expect(!draft.isCustomAnswerSelected)
        #expect(draft.customText == "Saved draft")
        #expect(builder.answer(for: question, draft: draft) == "Alpha")
    }

    @Test func multiSelectAfterCustomAnswerCanToggleEveryChoiceOff() {
        let question = question(
            id: "q",
            options: [.init(id: "a", label: "Alpha"), .init(id: "b", label: "Beta")],
            multiSelect: true
        )
        var draft = AgentFeedQuestionAnswerBuilder.Draft(customText: "Saved draft")

        draft.toggleOption("b", multiSelect: true)
        draft.toggleOption("a", multiSelect: true)

        #expect(builder.answer(for: question, draft: draft) == "Alpha, Beta")

        draft.toggleOption("b", multiSelect: true)
        draft.toggleOption("a", multiSelect: true)

        #expect(!draft.hasAnswer)
        #expect(!draft.isCustomAnswerSelected)
        #expect(draft.customText == "Saved draft")
        #expect(builder.answer(for: question, draft: draft) == nil)
    }

    private func question(
        id: String,
        options: [MobileAgentFeedQuestionOption],
        multiSelect: Bool = false
    ) -> MobileAgentFeedQuestion {
        MobileAgentFeedQuestion(
            id: id,
            prompt: "Prompt (\(id))",
            multiSelect: multiSelect,
            options: options
        )
    }
}
#endif
