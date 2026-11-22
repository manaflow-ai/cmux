import CmuxAgentQuestion
import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// Opening a chat shows its whole history at once: replayed history (a `.batch`)
/// is drawn in place, and only what arrives after the replay boundary animates in.
@MainActor
@Suite struct ChatOpenSnapshotTests {
    final class Silent: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "codex", agentName: "Codex", cwd: "~", workspaceTitle: "w", macName: "m")
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    static func turn(_ n: Int, at: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> [AgentSessionEvent] {
        [
            .userMessage(text: "prompt \(n)", promptId: "p\(n)", turnId: "t\(n)", attachments: [], at: at),
            .turnStarted(turnId: "t\(n)", at: at),
            .update(.agentMessageChunk(text: "answer ", messageId: "m\(n)")),
            .update(.agentMessageChunk(text: "\(n)", messageId: "m\(n)")),
            .turnResult(turnId: "t\(n)", status: .completed, errorText: nil, at: at),
        ]
    }

    @Test func replayedHistoryIsDrawnInPlace() {
        let store = AgentChatStore(source: Silent())
        store.apply(.batch((0..<3).flatMap { Self.turn($0) }))
        #expect(store.turns.map(\.id) == ["t0", "t1", "t2"])
        for turn in store.turns {
            #expect(store.isReplayed(turn.id))
            for row in turn.rows { #expect(store.isReplayed(row.id), "row \(row.id) of \(turn.id) would animate in") }
        }
    }

    @Test func onlyRecordsAfterTheBoundaryAnimate() {
        let store = AgentChatStore(source: Silent())
        store.apply(.batch(Self.turn(0)))
        // Live: a new turn and its answer.
        for event in Self.turn(1).dropLast() { store.apply(event) }
        #expect(!store.isReplayed("t1"))
        let rows = store.turns[1].rows
        #expect(!rows.isEmpty)
        for row in rows { #expect(!store.isReplayed(row.id)) }
        // History stays history.
        #expect(store.isReplayed("t0"))
        #expect(store.turns[0].rows.allSatisfy { store.isReplayed($0.id) })
    }

    /// A reattach catches up as a batch: what it brings is drawn in place, and what
    /// was shown live before keeps its view (no row is inserted twice).
    @Test func reattachCatchUpIsHistoryToo() {
        let store = AgentChatStore(source: Silent())
        store.apply(.batch(Self.turn(0)))
        for event in Self.turn(1) { store.apply(event) }
        store.apply(.batch(Self.turn(2)))
        #expect(store.turns.map(\.id) == ["t0", "t1", "t2"])
        #expect(store.isReplayed("t2"))
        #expect(store.turns[2].rows.allSatisfy { store.isReplayed($0.id) })
    }

    /// An ask that was already waiting when the chat opened is history: no haptic.
    @Test func pendingAskInHistoryIsReplayed() throws {
        let store = AgentChatStore(source: Silent())
        let ask = ACPPermissionRequest(id: "perm", toolCall: ACPToolCall(id: "c", title: "rm", kind: .execute),
                                       options: [ACPPermissionOption(id: "allow", name: "Allow", kind: .allowOnce)])
        let open = Self.turn(0).dropLast() + [.permissionRequest(ask)]
        store.apply(.batch(Array(open)))
        let pending = try #require(store.pendingPermission)
        #expect(store.isReplayed(TurnRow.permission(pending).id))
        #expect(store.wasOpenOnArrival(TurnRow.permission(pending).id))
    }

    /// An ask a reattach catches up on (raised while the link was down) is drawn in place
    /// but is news: it was not waiting when the chat opened, so it still buzzes.
    @Test func askCaughtUpOnReattachIsNews() throws {
        let store = AgentChatStore(source: Silent())
        store.apply(.batch(Self.turn(0)))
        let ask = ACPPermissionRequest(id: "later", toolCall: ACPToolCall(id: "c2", title: "rm", kind: .execute),
                                       options: [ACPPermissionOption(id: "allow", name: "Allow", kind: .allowOnce)])
        store.apply(.batch(Array(Self.turn(1).dropLast()) + [.permissionRequest(ask)]))
        let pending = try #require(store.pendingPermission)
        #expect(store.isReplayed(TurnRow.permission(pending).id))
        #expect(!store.wasOpenOnArrival(TurnRow.permission(pending).id))
    }

    /// An ask shown from the attach reply's pending list before its turn's records came
    /// moves to that turn when its own record arrives; an answered one is not shown again.
    @Test func askSeenAgainMovesToItsTurn() throws {
        let store = AgentChatStore(source: Silent())
        let ask = ACPPermissionRequest(id: "perm", toolCall: ACPToolCall(id: "c", title: "rm", kind: .execute),
                                       options: [ACPPermissionOption(id: "allow", name: "Allow", kind: .allowOnce)])
        store.apply(.batch(Self.turn(0) + [.permissionRequest(ask)]))
        store.apply(.userMessage(text: "next", promptId: "p1", turnId: "t1", attachments: [], at: Date()))
        store.apply(.turnStarted(turnId: "t1", at: Date()))
        store.apply(.permissionRequest(ask))
        #expect(store.pendingPermission?.request.id == "perm")
        let asks = store.turns.map { $0.items.filter { if case .permission = $0 { true } else { false } }.count }
        #expect(asks == [0, 1])
        store.apply(.permissionDecision(permissionId: "perm", optionId: "allow"))
        store.apply(.permissionRequest(ask))
        #expect(store.turns.flatMap(\.items).filter { if case .permission = $0 { true } else { false } }.count == 1)
    }

    /// An answered question shows what was chosen, from the answers the decision record
    /// carries (a chat opened on its history, or answered on the Mac). It used to show
    /// "You answered" over an empty bubble.
    @Test func answeredQuestionShowsTheRecordedAnswer() throws {
        let store = AgentChatStore(source: Silent())
        let request: AgentQuestionJSON = ["toolCall": ["toolCallId": "q1", "title": "Question", "kind": "other",
                                                        "rawInput": ["questions": [["question": "Which environment?", "header": "Pick",
                                                                                    "multiSelect": false,
                                                                                    "options": [["label": "A"], ["label": "B"]]]]],
                                                        "_meta": ["claude": ["tool": "AskUserQuestion", "interactive": true]]],
                                          "options": [["optionId": "allow_once", "name": "Answer", "kind": "allow_once"],
                                                      ["optionId": "reject_once", "name": "Reject", "kind": "reject_once"]]]
        let question = try #require(AgentQuestion(permissionRequest: request, permissionId: "q", session: "s1"))
        store.apply(.batch(Array(Self.turn(0).dropLast()) + [.question(question)]))
        store.apply(.permissionDecision(permissionId: "q", optionId: "allow_once", answers: ["Which environment?": "B"]))
        let shown = try #require(store.turns.last?.items.compactMap { if case .question(let q) = $0 { q } else { nil } }.first)
        guard case .answered(let answer) = shown.state else { Issue.record("not answered: \(shown.state)"); return }
        #expect(shown.summaryLines(answer) == ["Pick: B"])
    }

    /// An ACP question's choices are its permission options: "Dry run first" (not the first
    /// allow) is an answer, not Cancelled as before; Decline (its reject option) stays a decline.
    @Test(arguments: [("dry_run", "Dry run first"), ("stop", nil)])
    func anACPQuestionAnswersWithAnyChoiceButItsReject(_ option: String, _ label: String?) throws {
        let store = AgentChatStore(source: Silent())
        var question = try #require(try AgentQuestionFixture(name: "acp-interactive").mapped())
        question.state = .pending
        store.apply(.batch(Array(Self.turn(0).dropLast()) + [.question(question)]))
        store.apply(.permissionDecision(permissionId: question.id, optionId: option))
        let shown = try #require(store.turns.last?.items.compactMap { if case .question(let q) = $0 { q } else { nil } }.first)
        if let label {
            guard case .answered(let answer) = shown.state else { Issue.record("not answered: \(shown.state)"); return }
            #expect(shown.summaryLines(answer).first?.hasSuffix(label) == true)
        } else {
            #expect(shown.state == .cancelled)
        }
    }

    /// A chat with no history: its first live ask is news.
    @Test func firstLiveAskAfterEmptyHistoryIsNews() throws {
        let store = AgentChatStore(source: Silent())
        store.apply(.batch([.status(.idle)]))
        for event in Self.turn(0).dropLast() { store.apply(event) }
        let ask = ACPPermissionRequest(id: "perm", toolCall: ACPToolCall(id: "c", title: "rm", kind: .execute),
                                       options: [ACPPermissionOption(id: "allow", name: "Allow", kind: .allowOnce)])
        store.apply(.permissionRequest(ask))
        let pending = try #require(store.pendingPermission)
        #expect(!store.isReplayed(TurnRow.permission(pending).id))
        #expect(!store.wasOpenOnArrival(TurnRow.permission(pending).id))
    }

    /// A listed ask that a turn's end cancelled here (not a decision) opens again on the
    /// turn its own record lands in.
    @Test func askCancelledByTurnEndOpensAgainOnItsTurn() throws {
        let store = AgentChatStore(source: Silent())
        let ask = ACPPermissionRequest(id: "perm", toolCall: ACPToolCall(id: "c", title: "rm", kind: .execute),
                                       options: [ACPPermissionOption(id: "allow", name: "Allow", kind: .allowOnce)])
        store.apply(.batch(Array(Self.turn(0).dropLast()) + [.permissionRequest(ask)]))
        store.apply(.turnResult(turnId: "t0", status: .completed, errorText: nil, at: Date()))
        #expect(store.pendingPermission == nil)
        store.apply(.userMessage(text: "next", promptId: "p1", turnId: "t1", attachments: [], at: Date()))
        store.apply(.turnStarted(turnId: "t1", at: Date()))
        store.apply(.permissionRequest(ask))
        #expect(store.pendingPermission?.request.id == "perm")
        let asks = store.turns.map { $0.items.filter { if case .permission = $0 { true } else { false } }.count }
        #expect(asks == [0, 1])
    }
}
