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
