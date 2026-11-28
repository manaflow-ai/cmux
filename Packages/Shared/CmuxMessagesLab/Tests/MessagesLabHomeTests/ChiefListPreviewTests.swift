import AppKit
import CmuxAgentQuestion
import CmuxHomeCore
import CmuxHomeRender
import Foundation
import Testing
@testable import MessagesLabHome

/// The conversation list's second line (Cmux/ChiefListPreview.swift): a waiting card or a
/// running tool says so in plain words, else the newest bubble; never a system row, a finished
/// tool call, a question's options or a result card's meta line. Also the v3f light-theme and
/// memory-save fixes in the rows.
@MainActor @Suite struct ChiefListPreviewTests {
    static let me = ChiefRowsTests.me
    static let chief = ChiefRowsTests.chief

    static func message(_ seq: Seq, _ parts: [MessagePart], by author: ParticipantID = ParticipantID("agent_chief")) -> CmuxHomeCore.Message {
        CmuxHomeCore.Message(id: MessageID("m\(seq)"), conversation: ChiefRowsTests.id, seq: seq,
                             clientMessageID: IdempotencyKey("k\(seq)"), author: author, parts: parts,
                             createdAt: ChiefRowsTests.base.addingTimeInterval(Double(seq)))
    }

    static func line(_ messages: [CmuxHomeCore.Message]) -> ChiefListPreview.Line? {
        ChiefListPreview(messages: messages, me: me).line
    }

    static func question(_ state: AgentQuestion.State = .pending) -> AgentQuestion {
        let item = AgentQuestion.Item(id: "machine", header: "Machine", prompt: "Create a cloud machine?",
                                      options: [AgentQuestion.Option(id: "4g", label: "4 GB"), AgentQuestion.Option(id: "8g", label: "8 GB")],
                                      allowsOther: false)
        return AgentQuestion(id: "q-1", source: AgentQuestion.Source(harness: .chief, session: "sess", agentName: "Chief"),
                             items: [item], state: state, submitLabel: "Create")
    }

    static let ask = message(1, [.text("Please start Codex in Scratch", mentions: [])], by: me)
    static let answer = message(2, [.text("**On it.** Let me look.", mentions: [])])

    // MARK: Priority

    @Test func aWaitingDispatchApprovalNamesItsActionInPlainWords() {
        let card = Self.message(3, [.approval(ApprovalRef(request: "p1",
            prompt: "Run `cmux chief dispatch --agent codex --name Scratch --wait-working -- 'Run the tests'`?",
            options: ["Allow", "Deny"]))])
        #expect(Self.line([Self.ask, Self.answer, card]) == .needsApproval("Needs your approval: Start Codex in “Scratch”"))
        // Another command is named as itself, never "Run `…`?".
        let other = Self.message(3, [.approval(ApprovalRef(request: "p2", prompt: "Run `cmux vm new`?", options: ["Allow", "Deny"]))])
        #expect(Self.line([Self.ask, other])?.text == "Needs your approval: cmux vm new")
    }

    @Test func aWaitingQuestionShowsItsPromptNotItsOptions() {
        let question = Self.message(3, [.question(Self.question())])
        #expect(Self.line([Self.ask, question]) == .needsAnswer("Needs your answer: Create a cloud machine?"))
        // Answered: the newest bubble instead.
        let answer = AgentQuestionAnswer(selections: ["machine": AgentQuestionAnswer.Selection(optionIDs: ["4g"])])
        let answered = Self.message(3, [.question(Self.question(.answered(answer)))])
        #expect(Self.line([Self.ask, Self.answer, answered]) == .message(Self.answer))
    }

    @Test func aRunningToolShowsItsRowLine() {
        let running = Self.message(3, [ChiefRowsTests.work("t1", "cmux tree --all", .running)])
        #expect(Self.line([Self.ask, Self.answer, running]) == .running("Running cmux tree --all"))
        let dispatch = Self.message(3, [ChiefRowsTests.work("t2", "cmux chief dispatch --agent codex --name Scratch -- 'x'", .running)])
        #expect(Self.line([Self.ask, dispatch])?.text == "Starting Codex in “Scratch”")
    }

    @Test func otherwiseTheNewestBubbleNeverASystemRowOrFinishedTool() {
        let ran = Self.message(3, [ChiefRowsTests.work("t1", "cmux chief memory add \"Prefers 14 pt font\"", .done)])
        let note = Self.message(4, [.work(WorkRef(session: ChiefRows.memoryPrefix + "t:m-1", title: "Prefers 14 pt font", status: .done))])
        let stopped = Self.message(5, [.work(WorkRef(session: ChiefRows.stoppedPrefix + "s1", title: "Stopped", status: .done))])
        let failure = Self.message(6, [.work(WorkRef(session: ChiefRows.failurePrefix + "f1", title: "I couldn't finish.", status: .failed))])
        let allowed = Self.message(7, [.approval(ApprovalRef(request: "p1", prompt: "Run `cmux tree`?", options: ["Allow", "Deny"],
                                                             decided: "Allow"))])
        #expect(Self.line([Self.ask, Self.answer, ran, note, stopped, failure, allowed]) == .message(Self.answer))
        // My message is the newest bubble right after I send.
        #expect(Self.line([Self.answer, Self.ask]) == .message(Self.ask))
    }

    @Test func aResultCardShowsItsTitleNotItsMetaLine() {
        let card = Self.message(3, [.work(WorkRef(session: "ws_962f", host: "vm-794a", title: "Codex needs sign-in on chief-dogfood-1",
                                                  status: .waiting, preview: "README title · ws_962f · waiting at sign-in"))])
        #expect(Self.line([Self.ask, card]) == .card("Codex needs sign-in on chief-dogfood-1"))
    }

    @Test func aCardOlderThanMyLastMessageNoLongerWaits() {
        let card = Self.message(1, [.approval(ApprovalRef(request: "p1", prompt: "Run `cmux vm new`?", options: ["Allow", "Deny"]))])
        let later = Self.message(2, [.text("never mind", mentions: [])], by: Self.me)
        #expect(Self.line([card, later]) == .message(later))
        #expect(Self.line([]) == nil)
    }

    // MARK: Memory save row

    @Test func aFinishedMemorySaveShowsNoRowTheNoteIsItsReceipt() {
        let save = ChiefRowsTests.item(1, [ChiefRowsTests.work("t1", "cmux chief memory add \"Prefers 14 pt font\"", .done)])
        let tree = ChiefRowsTests.item(2, [ChiefRowsTests.work("t2", "cmux tree --all", .done)])
        let roles = ChiefRows.roles([save, tree])
        #expect(roles.value(for: IdempotencyKey("k1")) == .folded)
        // The next call is a row of its own, not folded into the hidden save.
        #expect(roles.value(for: IdempotencyKey("k2")) == .head([ChiefRows.ToolCall(id: "t2", title: "cmux tree --all", state: .done,
                                                                                     detail: "cmux tree --all")], allowed: false))
        // While it runs, or when it failed, the row shows.
        let running = ChiefRowsTests.item(1, [ChiefRowsTests.work("t1", "cmux chief memory add x", .running)])
        #expect(ChiefRows.roles([running]).value(for: IdempotencyKey("k1")) != .folded)
        #expect(ChiefRows.isMemorySave("CMUX_CHIEF_HOME=/tmp/h /opt/bin/cmux chief memory add x"))
        #expect(!ChiefRows.isMemorySave("cmux chief memory list"))
    }

    // MARK: Light theme

    @Test func aLightThemeWithTheMeasuredAccentDrawsIMessageBlueWithWhiteText() {
        let light = HomePalette.themed(HomePalette.Theme(background: .gray255(255), foreground: .gray255(29),
                                                         accent: .rgb255(2, 132, 254), failure: .rgb255(255, 59, 48)))
        let theme = FixtureTheme(active: light, inactive: light, measuredAccent: true)
        #expect(!theme.measuredAccent)
        let blue = theme.active.outgoing.usingColorSpace(.sRGB)
        #expect(blue.map { abs($0.redComponent * 255 - 2) < 0.5 && abs($0.greenComponent * 255 - 132) < 0.5
                && abs($0.blueComponent * 255 - 254) < 0.5 } == true)
        #expect(theme.active.outgoingText == .white)
        #expect(theme.active.gradientStops.count == Fixture.gradientStops.count)
        // A dark theme keeps the vendored palette's measured path.
        let dark = HomePalette.themed(HomePalette.Theme(background: .gray255(18), foreground: .gray255(230),
                                                        accent: .rgb255(2, 132, 254), failure: .rgb255(255, 59, 48)))
        #expect(FixtureTheme(active: dark, inactive: dark, measuredAccent: true).measuredAccent)
    }

    @Test func theComposeGlassIsTintedOnlyOnALightTheme() {
        #expect(FieldChrome.glassTint(light: false, background: .white) == nil)
        let tint = FieldChrome.glassTint(light: true, background: .white)
        #expect(tint.map { abs($0.alphaComponent - FieldChrome.lightGlassTintAlpha) < 0.001 } == true)
    }
}
