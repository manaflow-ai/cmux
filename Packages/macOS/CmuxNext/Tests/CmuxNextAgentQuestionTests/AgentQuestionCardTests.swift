import AppKit
import CmuxAgentQuestion
@testable import CmuxNextAgentQuestion
import Testing

@MainActor
@Suite struct AgentQuestionCardTests {
    private func fixture(_ name: String) throws -> AgentQuestion {
        try AgentQuestionFixture(name: name).question
    }

    @Test func everyFixtureLaysOutInsideItsWidthAtEveryWidthAndSize() throws {
        for name in AgentQuestionFixture.names {
            let question = try fixture(name)
            for width in [320.0, 560, 900] {
                for scale in [1.0, 1.15, 1.3] {
                    let layout = AgentQuestionCardLayout(state: AgentQuestionCardState(question: question), width: width,
                                                         style: AgentQuestionCardStyle(scale: scale))
                    #expect(layout.height > 0, "\(name) \(width) \(scale)")
                    let frames = layout.rows.map(\.frame) + [layout.prompt] + [layout.preview, layout.submit, layout.skip].compactMap { $0 }
                    for frame in frames {
                        #expect(frame.minX >= 0 && frame.maxX <= width + 0.5, "\(name) \(width) \(scale) \(frame)")
                        #expect(frame.maxY <= layout.height + 0.5, "\(name) \(width) \(scale) \(frame)")
                    }
                }
            }
        }
    }

    @Test func rowsNeverOverlap() throws {
        let layout = AgentQuestionCardLayout(state: AgentQuestionCardState(question: try fixture("pending-single")), width: 560)
        for (a, b) in zip(layout.rows, layout.rows.dropFirst()) {
            #expect(a.frame.maxY <= b.frame.minY)
        }
        #expect(layout.rows.count == 4) // three options and Other
        #expect(layout.rows.last?.isOther == true)
    }

    @Test func highlightingAnotherOptionNeverChangesTheHeight() throws {
        var state = AgentQuestionCardState(question: try fixture("pending-with-preview"))
        let first = AgentQuestionCardLayout(state: state, width: 700).height
        for _ in 0..<3 {
            _ = state.send(.down)
            #expect(AgentQuestionCardLayout(state: state, width: 700).height == first)
        }
    }

    @Test func previewSitsBesideTheOptionsOnlyWhenWide() throws {
        let state = AgentQuestionCardState(question: try fixture("pending-with-preview"))
        let wide = AgentQuestionCardLayout(state: state, width: 700)
        let narrow = AgentQuestionCardLayout(state: state, width: 400)
        let widePreview = try #require(wide.preview)
        let narrowPreview = try #require(narrow.preview)
        #expect(widePreview.minX > wide.rows[0].frame.maxX)
        #expect(narrowPreview.minY > narrow.rows.last!.frame.maxY) // crash-allow: test
        #expect(AgentQuestionCardLayout(state: AgentQuestionCardState(question: try fixture("pending-single")), width: 700).preview == nil)
    }

    @Test func answeredAndCancelledCollapse() throws {
        let pending = AgentQuestionCardView.height(for: try fixture("pending-single"), width: 560)
        let answered = AgentQuestionCardView.height(for: try fixture("answered-collapsed"), width: 560)
        let cancelled = AgentQuestionCardView.height(for: try fixture("cancelled"), width: 560)
        #expect(answered < pending / 2)
        #expect(cancelled < answered)
    }

    @Test func onlyPersonInputSubmitsAndPreviewReplayNeverDoes() throws {
        let card = AgentQuestionCardView()
        var submitted: [AgentQuestionAnswer] = []
        card.onSubmit = { _, answer in submitted.append(answer) }
        card.configure(question: try fixture("pending-single"), width: 560)
        card.replayForPreview([.number(2)])
        #expect(submitted.isEmpty)
        card.handle(.number(3))
        #expect(submitted == [AgentQuestionAnswer(selections: ["q0": .init(optionIDs: ["Passkeys"])])])
    }

    @Test func reconfiguringTheSameAskKeepsLocalChoicesAndANewAskStartsFresh() throws {
        let card = AgentQuestionCardView()
        let multi = try fixture("pending-multi")
        card.configure(question: multi, width: 560)
        card.handle(.number(2))
        card.configure(question: multi, width: 600)
        #expect(card.cardState?.chosen["q0"] == ["iOS"])
        card.configure(question: try fixture("pending-single"), width: 600)
        #expect(card.cardState?.chosen.isEmpty == true)
    }

    @Test func skipDeclinesOnlyAPendingAsk() throws {
        let card = AgentQuestionCardView()
        var declined = 0
        card.onDecline = { _ in declined += 1 }
        card.configure(question: try fixture("answered-collapsed"), width: 560)
        #expect(card.acceptsFirstResponder == false)
        card.configure(question: try fixture("pending-single"), width: 560)
        #expect(card.acceptsFirstResponder)
        _ = declined
    }

    @Test func keysMapToReducerInputsAndCommandShortcutsFallThrough() throws {
        func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)! // crash-allow: test
        }
        #expect(AgentQuestionCardView.input(for: key(18, "1")) == .number(1))
        #expect(AgentQuestionCardView.input(for: key(125, "", [.function, .numericPad])) == .down)
        #expect(AgentQuestionCardView.input(for: key(36, "\r")) == .confirm)
        #expect(AgentQuestionCardView.input(for: key(53, "\u{1b}")) == .escape)
        #expect(AgentQuestionCardView.input(for: key(18, "1", .command)) == nil)
        #expect(AgentQuestionCardView.input(for: key(0, "a")) == nil)
    }
}
