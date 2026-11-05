import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// The agent's wrap-up box on the phone: acpmux's `wrap_up` call read as the next-step card with
/// its recap (the Mac's `wrapUp.ts`). Leo, 2026-11-05: "I don't see the box in iOS, in the app."
@MainActor
@Suite struct WrapUpTests {
    static let at = Date(timeIntervalSince1970: 1_700_000_000)

    static func wrapUpCall(_ args: [String: JSONValue], title: String = "mcp__acpmux__wrap_up", status: ACPToolCall.Status = .completed) -> ACPToolCall {
        ACPToolCall(id: "w1", title: title, kind: .other, status: status, rawInput: .object(args))
    }

    static func rows(answer: String, call: ACPToolCall, then next: String? = nil) -> [ChatTurnRows] {
        let store = AgentChatStore(source: PromptResendTests.Recorder())
        var events: [AgentSessionEvent] = [
            .userMessage(text: "refactor it", promptId: "p1", turnId: "t1", attachments: [], at: at),
            .turnStarted(turnId: "t1", at: at),
            .update(.agentMessageChunk(text: answer, messageId: "m1")),
            .update(.toolCall(call)),
            .turnResult(turnId: "t1", status: .completed, errorText: nil, at: at),
        ]
        if let next {
            events += [.userMessage(text: next, promptId: "p2", turnId: "t2", attachments: [], at: at), .turnStarted(turnId: "t2", at: at)]
        }
        store.apply(.batch(events))
        return ChatTranscriptBuilder(diffs: ChatDiffCache()).build(turns: store.turns, pendingPermission: nil, askOpen: false,
                                                                   permissionBarHidden: false)
    }

    static func hasToolRow(_ rows: [ChatTurnRows]) -> Bool {
        rows.flatMap(\.rows).contains { row in
            switch row.kind {
            case .tool, .toolGroup: true
            default: false
            }
        }
    }

    // MARK: Reading the call

    @Test func aRecapWithAnAskAndTwoAnswers() throws {
        let call = Self.wrapUpCall(["recap": .string("Fixed the bug."), "ask": .string("Merge it?"), "actions": .array([.string("Merge"), .object(["label": .string("Hold")])])])
        #expect(NextStepAsk.isWrapUp(call))
        let ask = try #require(NextStepAsk.wrapUp(call))
        #expect(ask.tag == "wrap_up")
        #expect(ask.recap == "Fixed the bug.")
        #expect(ask.question == "Merge it?")
        #expect(ask.options.map(\.label) == ["Merge", "Hold"])
    }

    @Test func anAskWithoutAnswersGetsYesAndNotNow() throws {
        let ask = try #require(NextStepAsk.wrapUp(Self.wrapUpCall(["recap": .string("Done."), "ask": .string("Push it?")])))
        #expect(ask.options.map(\.kind) == [.yes, .notNow])
    }

    @Test func aRecapAloneHasNoQuestion() throws {
        let ask = try #require(NextStepAsk.wrapUp(Self.wrapUpCall(["recap": .string("Done.")])))
        #expect(ask.question.isEmpty)
        #expect(ask.options.isEmpty)
    }

    @Test func everyNameTheCallGoesBy() {
        #expect(NextStepAsk.isWrapUp(Self.wrapUpCall([:], title: "mcp__cmux__acpmux_wrap_up")))
        #expect(NextStepAsk.isWrapUp(Self.wrapUpCall([:], title: "wrap_up")))
        let codex = ACPToolCall(id: "w", title: "acpmux.wrap_up call", kind: .other, status: .completed,
                                rawInput: .object(["server": .string("acpmux"), "tool": .string("wrap_up"), "arguments": .object(["recap": .string("Done.")])]))
        #expect(NextStepAsk.isWrapUp(codex))
        #expect(NextStepAsk.wrapUp(codex)?.recap == "Done.")
        #expect(!NextStepAsk.isWrapUp(Self.wrapUpCall([:], title: "mcp__other__wrap_up")))
        #expect(!NextStepAsk.isWrapUp(Self.wrapUpCall([:], title: "Read wrap_up.rs")))
    }

    @Test func emptyOrFailedCallsDrawNone() {
        #expect(NextStepAsk.wrapUp(Self.wrapUpCall([:])) == nil)
        #expect(NextStepAsk.wrapUp(Self.wrapUpCall(["recap": .string("Done.")], status: .failed)) == nil)
    }

    @Test func aScriptThatOnlyWrappedUpIsTheCard() throws {
        let answer = #"{"calls":1,"call_log":[{"name":"acpmux_wrap_up","ok":true,"shown":{"recap":"Landed it.","ask":"Next one?"}}]}"#
        let script = ACPToolCall(id: "x", title: "mcp__cmux__cmux_exec", kind: .other, status: .completed,
                                 content: [.content(.text(answer))],
                                 rawInput: .object(["script": .string("await cmux.acpmux_wrap_up({recap: 'Landed it.'})")]))
        #expect(!NextStepAsk.isWrapUp(script))
        let exec = try #require(NextStepAsk.execWrapUp(script))
        #expect(exec.only)
        #expect(NextStepAsk.wrapUp(script)?.recap == "Landed it.")
        #expect(NextStepAsk.drawsWrapUp(script))
    }

    // MARK: The transcript

    @Test func theLastTurnDrawsTheBoxAndDropsTheCallsRow() throws {
        let rows = Self.rows(answer: "Done.", call: Self.wrapUpCall(["recap": .string("Fixed it."), "ask": .string("Merge?"), "actions": .array([.string("Merge"), .string("Hold")])]))
        let card = try #require(NewMacRowsTests.nextStep(rows))
        #expect(card.0.recap == "Fixed it.")
        #expect(card.0.options.map(\.label) == ["Merge", "Hold"])
        #expect(card.1 == nil && card.2, "the last turn's box answers")
        #expect(!Self.hasToolRow(rows))
        let kinds = try #require(rows.last?.rows.map(\.kind))
        let box = try #require(kinds.firstIndex { if case .nextStep = $0 { true } else { false } })
        let footer = try #require(kinds.firstIndex { if case .actions = $0 { true } else { false } })
        #expect(box < footer)
    }

    @Test func aReplyFoldsTheBoxToItsAnswer() throws {
        let rows = Self.rows(answer: "Done.", call: Self.wrapUpCall(["recap": .string("Fixed it."), "ask": .string("Merge?"), "actions": .array([.string("Merge"), .string("Hold")])]),
                             then: "merge")
        let card = try #require(NewMacRowsTests.nextStep(rows))
        #expect(card.1 == "Merge")
        #expect(!card.2)
    }

    @Test func theWrapUpGoesBeforeATaggedAsk() throws {
        let rows = Self.rows(answer: "Done.\n\n[taste] Which icon?\n- Folder\n- Stack", call: Self.wrapUpCall(["recap": .string("Fixed it.")]))
        let card = try #require(NewMacRowsTests.nextStep(rows))
        #expect(card.0.tag == "wrap_up")
        #expect(rows.flatMap(\.rows).filter { if case .nextStep = $0.kind { true } else { false } }.count == 1)
    }

    @Test func aFailedCallKeepsItsRow() {
        let rows = Self.rows(answer: "Done.", call: Self.wrapUpCall(["recap": .string("Fixed it.")], status: .failed))
        #expect(NewMacRowsTests.nextStep(rows) == nil)
        #expect(Self.hasToolRow(rows))
    }
}
