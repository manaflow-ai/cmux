@testable import CmuxNextFeed
import Foundation
import Testing

@MainActor
struct FeedChoiceValidationTests {
    private let prompt = FeedPrompt.Choice(questions: [
        .init(id: "auth", question: "Method?", options: [.init(id: "a", label: "A"), .init(id: "b", label: "B")]),
        .init(id: "scope", question: "Commands?", options: [.init(id: "x", label: "X"), .init(id: "y", label: "Y")],
              multi: true, allowOther: true),
    ])

    @Test func everyQuestionNeedsAnAnswer() {
        #expect(FeedChoiceValidation.issues([:], for: prompt) == [.unanswered(question: "auth"), .unanswered(question: "scope")])
    }

    @Test func singleSelectTakesOneOption() {
        let answers: [String: FeedChoiceSelection] = ["auth": .init(selected: ["a", "b"]), "scope": .init(selected: ["x"])]
        #expect(FeedChoiceValidation.issues(answers, for: prompt) == [.tooMany(question: "auth")])
    }

    @Test func multiSelectTakesSeveralOptionsAndOther() {
        let answers: [String: FeedChoiceSelection] = ["auth": .init(selected: ["a"]), "scope": .init(selected: ["x", "y"], other: "logs")]
        #expect(FeedChoiceValidation.issues(answers, for: prompt).isEmpty)
    }

    @Test func otherOnlyWhereAllowed() {
        let answers: [String: FeedChoiceSelection] = ["auth": .init(other: "SSO"), "scope": .init(other: "logs")]
        #expect(FeedChoiceValidation.issues(answers, for: prompt) == [.otherNotAllowed(question: "auth")])
    }

    @Test func otherAloneAnswersAQuestionAndBlankOtherDoesNot() {
        let answers: [String: FeedChoiceSelection] = ["auth": .init(selected: ["b"]), "scope": .init(other: "  ")]
        #expect(FeedChoiceValidation.issues(answers, for: prompt) == [.unanswered(question: "scope")])
        let normalized = FeedChoiceValidation.normalized(["auth": .init(selected: ["b"]), "scope": .init(selected: ["y"], other: " ")], for: prompt)
        #expect(normalized?["scope"] == FeedChoiceSelection(selected: ["y"], other: nil))
    }

    @Test func unknownIdsAreRefused() {
        let answers: [String: FeedChoiceSelection] = ["auth": .init(selected: ["z"]), "scope": .init(selected: ["x"]), "extra": .init(selected: ["a"])]
        #expect(FeedChoiceValidation.issues(answers, for: prompt) == [.unknownQuestion("extra"), .unknownOption(question: "auth", option: "z")])
    }

    @Test func toggleKeepsOneOptionOnSingleSelect() {
        var selection = FeedChoiceSelection(other: "typed")
        selection.toggle("a", multi: false)
        selection.toggle("b", multi: false)
        #expect(selection == FeedChoiceSelection(selected: ["b"]))
        var multi = FeedChoiceSelection()
        multi.toggle("x", multi: true)
        multi.toggle("y", multi: true)
        multi.toggle("x", multi: true)
        #expect(multi.selected == ["y"])
    }

    @Test func submitSendsOnlyAValidChoice() {
        let (model, _) = startedFeed(echo: false)
        guard case let .choice(seeded) = model.item("fi_claude_choice")?.prompt else {
            Issue.record("seeded choice missing")
            return
        }
        #expect(!model.submitChoice("fi_claude_choice").isEmpty)
        #expect(model.pending.isEmpty)
        model.drafts.toggle("fi_claude_choice", question: seeded.questions[0], option: "device")
        model.drafts.toggle("fi_claude_choice", question: seeded.questions[1], option: "push")
        model.drafts.setOther("fi_claude_choice", question: seeded.questions[1], text: "status")
        #expect(model.submitChoice("fi_claude_choice").isEmpty)
        #expect(model.pending.count == 1)
        guard case let .answer(_, .choice(sent))? = model.pending.first?.kind else {
            Issue.record("no choice answer sent")
            return
        }
        #expect(sent["q_scope"] == FeedChoiceSelection(selected: ["push"], other: "status"))
        #expect(model.drafts.choices["fi_claude_choice"] == nil, "a sent answer clears its draft")
    }
}
