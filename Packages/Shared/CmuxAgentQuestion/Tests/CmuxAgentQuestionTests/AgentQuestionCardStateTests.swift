import CmuxAgentQuestion
import Foundation
import Testing

@Suite struct AgentQuestionCardStateTests {
    private func state(_ name: String) throws -> AgentQuestionCardState {
        AgentQuestionCardState(question: try AgentQuestionFixture(name: name).question)
    }

    @Test func numberKeyChoosesAndSubmitsASingleQuestion() throws {
        var card = try state("pending-single")
        let effect = card.send(.number(3))
        #expect(effect == .submit(AgentQuestionAnswer(selections: ["q0": .init(optionIDs: ["Passkeys"])])))
    }

    @Test func arrowsMoveTheHighlightAndEnterChoosesIt() throws {
        var card = try state("pending-single")
        #expect(card.send(.down) == .none)
        #expect(card.send(.down) == .none)
        #expect(card.send(.down) == .none) // the Other row
        #expect(card.send(.down) == .none) // clamps
        #expect(card.highlightedRow(card.item) == 3)
        #expect(card.send(.up) == .none)
        #expect(card.send(.confirm) == .submit(AgentQuestionAnswer(selections: ["q0": .init(optionIDs: ["Passkeys"])])))
    }

    @Test func multiSelectTogglesAndEnterSubmits() throws {
        var card = try state("pending-multi")
        #expect(card.send(.number(1)) == .none)
        #expect(card.send(.number(4)) == .none)
        #expect(card.send(.number(1)) == .none) // untoggles macOS
        #expect(card.send(.number(5)) == .beginOtherEditing) // the Other row
        #expect(card.editingOther)
        #expect(card.send(.otherText("visionOS")) == .none)
        #expect(card.send(.confirm) == .submit(AgentQuestionAnswer(selections: ["q0": .init(optionIDs: ["Web"], other: "visionOS")])))
    }

    @Test func multiSelectEnterWithNothingChosenDoesNotSubmit() throws {
        var card = try state("pending-multi")
        #expect(card.send(.confirm) == .none)
        #expect(!card.canSubmit)
    }

    @Test func otherRowStartsEditingAndTextAnswersSingleSelect() throws {
        var fresh = try state("pending-other-typing")
        #expect(fresh.send(.number(4)) == .beginOtherEditing)
        #expect(fresh.send(.otherText("Mutual TLS")) == .none)
        #expect(fresh.send(.escape) == .none) // leaves the field, keeps the draft
        #expect(!fresh.editingOther)
        #expect(fresh.send(.submit) == .submit(AgentQuestionAnswer(selections: ["q0": .init(other: "Mutual TLS")])))
    }

    @Test func severalQuestionsAdvanceToTheNextUnansweredThenSubmit() throws {
        var card = try state("pending-4-questions")
        #expect(card.send(.number(2)) == .none)
        #expect(card.activeItem == 1)
        #expect(card.send(.number(1)) == .none) // multi: toggle macOS
        #expect(card.send(.confirm) == .none)
        #expect(card.activeItem == 2)
        #expect(card.send(.number(1)) == .none)
        #expect(card.activeItem == 3)
        let effect = card.send(.number(1))
        guard case .submit(let answer) = effect else { Issue.record("expected submit, got \(effect)"); return }
        #expect(answer.selections["q0"]?.optionIDs == ["API keys"])
        #expect(answer.selections["q1"]?.optionIDs == ["macOS"])
        #expect(answer.selections["q3"]?.optionIDs == ["Yes, off by default"])
    }

    @Test func answeredAndCancelledCardsIgnoreInputAndEscapeResigns() throws {
        for name in ["answered-collapsed", "cancelled"] {
            var card = try state(name)
            #expect(card.send(.number(1)) == .none, "\(name)")
            #expect(card.send(.submit) == .none, "\(name)")
            #expect(card.send(.escape) == .resign, "\(name)")
        }
    }

    @Test func escapeOutsideTheOtherFieldResignsWithoutAnswering() throws {
        var card = try state("pending-single")
        #expect(card.send(.escape) == .resign)
        #expect(card.question.isPending)
    }

    @Test func outOfRangeNumbersDoNothing() throws {
        var card = try state("acp-interactive") // three options, no Other row
        #expect(card.send(.number(4)) == .none)
        #expect(card.send(.number(0)) == .none)
        #expect(card.send(.click(row: 9)) == .none)
    }
}
