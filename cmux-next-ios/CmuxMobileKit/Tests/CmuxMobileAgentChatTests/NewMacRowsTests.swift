import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// The Mac's agent-pane rows after 2026-10-26 on the phone (cmux#25834): the next-step card a
/// tagged ask draws (#33269, the Mac's `nextStepAsk.test.ts` cases) and Continue or Retry leading
/// a failed turn's error card.
@MainActor
@Suite struct NewMacRowsTests {
    // MARK: Reading the ask (the Mac's cases)

    @Test func aTaggedQuestionWithAListDrawsItsAnswers() throws {
        let text = "Done with the refactor.\n\n**[taste]** Which icon should the sidebar use?\n- Folder\n- Stack\n- Grid\n"
        let ask = try #require(NextStepAsk.parse(text))
        #expect(ask.tag == "taste")
        #expect(ask.question == "Which icon should the sidebar use?")
        #expect(ask.options.map(\.label) == ["Folder", "Stack", "Grid"])
        #expect(ask.rest == "Done with the refactor.")
    }

    @Test func aYesOrNoQuestionGetsYesAndNotNow() throws {
        let ask = try #require(NextStepAsk.parse("All green.\n\n[outward] For Leo: should I merge #123? My pick: yes."))
        #expect(ask.question == "Should I merge #123?")
        #expect(ask.detail == "My pick: yes.")
        #expect(ask.options.map(\.kind) == [.yes, .notNow])
        #expect(ask.options.map(\.label) == ["Yes", "Not now"])
    }

    @Test func proseCodeQuotesAndTwoAsksDrawNone() {
        #expect(NextStepAsk.parse("Which file next? Probably a.swift.") == nil)
        #expect(NextStepAsk.parse("```\n[taste] Which one?\n- a\n- b\n```") == nil)
        #expect(NextStepAsk.parse("> [taste] Which one?\n- a\n- b") == nil)
        #expect(NextStepAsk.parse("[taste] Which one?\n- a\n- b\n\n[outward] Should I push?") == nil)
        // An open question without answers to tap.
        #expect(NextStepAsk.parse("[taste] Which color do you like?") == nil)
        // A question mark only inside code is not a question.
        #expect(NextStepAsk.parse("[taste] Run `ls ?` now") == nil)
        // One answer, or five, is not a choice to draw.
        #expect(NextStepAsk.parse("[taste] Which one?\n- a") == nil)
        #expect(NextStepAsk.parse("[taste] Which one?\n- a\n- b\n- c\n- d\n- e") == nil)
    }

    @Test func theAnswerGivenReadsBack() throws {
        let ask = try #require(NextStepAsk.parse("[taste] Which one?\n- Folder\n- Stack"))
        #expect(ask.chosenAnswer(" stack ") == "Stack")
        #expect(ask.chosenAnswer("Neither, use a grid\nand smaller") == "Neither, use a grid")
    }

    // MARK: The transcript

    static let at = Date(timeIntervalSince1970: 1_700_000_000)

    static func store(answer: String, then next: String? = nil) -> (AgentChatStore, PromptResendTests.Recorder) {
        let source = PromptResendTests.Recorder()
        let store = AgentChatStore(source: source)
        var events: [AgentSessionEvent] = [
            .userMessage(text: "refactor it", promptId: "p1", turnId: "t1", attachments: [], at: at),
            .turnStarted(turnId: "t1", at: at),
            .update(.agentMessageChunk(text: answer, messageId: "m1")),
            .turnResult(turnId: "t1", status: .completed, errorText: nil, at: at),
        ]
        if let next {
            events += [.userMessage(text: next, promptId: "p2", turnId: "t2", attachments: [], at: at), .turnStarted(turnId: "t2", at: at)]
        }
        store.apply(.batch(events))
        return (store, source)
    }

    static func nextStep(_ rows: [ChatTurnRows]) -> (NextStepAsk, String?, Bool)? {
        for case .nextStep(let ask, let answer, let canAnswer) in rows.flatMap(\.rows).map(\.kind) { return (ask, answer, canAnswer) }
        return nil
    }

    @Test func aFinishedTurnsAskDrawsAsACardUnderItsAnswer() throws {
        let (store, _) = Self.store(answer: "Done.\n\n[taste] Which icon?\n- Folder\n- Stack")
        let rows = ChatTranscriptBuilder(diffs: ChatDiffCache()).build(turns: store.turns, pendingPermission: nil, askOpen: false,
                                                                         permissionBarHidden: false)
        let card = try #require(Self.nextStep(rows))
        #expect(card.0.options.map(\.label) == ["Folder", "Stack"])
        #expect(card.1 == nil && card.2, "the last turn's card answers")
        // The answer's own text draws without the ask's lines.
        let blocks = rows.flatMap(\.rows).compactMap { row -> String? in
            if case .block(_, let block) = row.kind { return AgentChatFind.text(of: block.kind) }
            return nil
        }
        #expect(blocks.joined(separator: " ").contains("Done."))
        #expect(!blocks.joined(separator: " ").contains("Which icon"))
        // The card follows the answer, before the turn's footer.
        let kinds = try #require(rows.last?.rows.map(\.kind))
        let card0 = try #require(kinds.firstIndex { if case .nextStep = $0 { true } else { false } })
        let footer = try #require(kinds.firstIndex { if case .actions = $0 { true } else { false } })
        #expect(card0 < footer)
    }

    @Test func aPromptAfterTheCardFoldsItToTheAnswer() throws {
        let (store, _) = Self.store(answer: "[taste] Which icon?\n- Folder\n- Stack", then: "stack")
        let rows = ChatTranscriptBuilder(diffs: ChatDiffCache()).build(turns: store.turns, pendingPermission: nil, askOpen: false,
                                                                         permissionBarHidden: false)
        let card = try #require(Self.nextStep(rows))
        #expect(card.1 == "Stack")
        #expect(!card.2)
    }

    @Test func aRunningTurnDrawsNoCard() {
        let source = PromptResendTests.Recorder()
        let store = AgentChatStore(source: source)
        store.apply(.batch([
            .userMessage(text: "go", promptId: "p1", turnId: "t1", attachments: [], at: Self.at),
            .turnStarted(turnId: "t1", at: Self.at),
            .update(.agentMessageChunk(text: "[taste] Which icon?\n- Folder\n- Stack", messageId: "m1")),
        ]))
        let rows = ChatTranscriptBuilder(diffs: ChatDiffCache()).build(turns: store.turns, pendingPermission: nil, askOpen: false,
                                                                         permissionBarHidden: false)
        #expect(Self.nextStep(rows) == nil)
    }

    @Test func anEarlierAskWithoutAReplyStaysInItsText() throws {
        let (store, _) = Self.store(answer: "Done.\n\n[taste] Which icon?\n- Folder\n- Stack", then: " ")
        let rows = ChatTranscriptBuilder(diffs: ChatDiffCache()).build(turns: store.turns, pendingPermission: nil, askOpen: false,
                                                                         permissionBarHidden: false)
        #expect(Self.nextStep(rows) == nil)
    }

    @Test func anAnswersLabelIsThePromptItSends() throws {
        let (store, source) = Self.store(answer: "[outward] Should I push?")
        let ask = try #require(Self.nextStep(ChatTranscriptBuilder(diffs: ChatDiffCache()).build(
            turns: store.turns, pendingPermission: nil, askOpen: false, permissionBarHidden: false)))
        store.send(prompt: try #require(ask.0.options.first).label)
        #expect(PromptResendTests.prompt(source.sent.last)?.text == "Yes")
    }

    // MARK: Continue or Retry

    @Test func aFailedTurnThatDidWorkLeadsWithContinue() throws {
        let (store, _) = Self.failed(withWork: true)
        #expect(try #require(store.turns.last).continuesAfterFailure)
        let (bare, _) = Self.failed(withWork: false)
        #expect(try #require(bare.turns.last).continuesAfterFailure == false)
    }

    @Test func continueSendsAcpmuxsTurnRetry() throws {
        let (store, source) = Self.failed(withWork: true)
        store.retryFailedTurn(try #require(store.turns.last))
        #expect(source.sent == [.retryFailedTurn])
    }

    static func failed(withWork: Bool) -> (AgentChatStore, PromptResendTests.Recorder) {
        let source = PromptResendTests.Recorder()
        let store = AgentChatStore(source: source)
        var events: [AgentSessionEvent] = [
            .userMessage(text: "do it", promptId: "p1", turnId: "t1", attachments: [], at: at),
            .turnStarted(turnId: "t1", at: at),
        ]
        if withWork { events.append(.update(.agentMessageChunk(text: "Working on it.", messageId: "m1"))) }
        events.append(.turnResult(turnId: "t1", status: .failed, errorText: "rate limited", at: at))
        store.apply(.batch(events))
        return (store, source)
    }
}
