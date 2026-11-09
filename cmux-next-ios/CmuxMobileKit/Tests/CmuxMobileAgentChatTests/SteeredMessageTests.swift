@testable import CmuxMobileAgentChat
import Foundation
import Testing

/// A message steered into a running turn draws in that turn, where it went in, as the Mac's
/// transcript does: the person's as their bubble, another agent's as its card. Leo, 2026-11-05:
/// "WHY THE F*** ARE MY MESSAGES BEING QUEUED INSTEAD OF STEERING".
@Suite struct SteeredMessageTests {
    final class Recorder: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m")
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    func steers(_ turn: AgentTurn?) -> [SteeredMessage] {
        (turn?.items ?? []).compactMap { if case .steer(let message) = $0 { message } else { nil } }
    }

    @MainActor @Test func thePersonsSteerDrawsInItsTurn() throws {
        let store = AgentChatStore(source: Recorder())
        store.apply(.userMessage(text: "Fix the grid", promptId: "p-1", turnId: "t-1", attachments: [], at: Date()))
        store.apply(.turnStarted(turnId: "t-1", at: Date()))
        store.apply(.update(.agentMessageChunk(text: "Looking at the grid.", messageId: "m-1")))
        store.apply(.userMessage(text: "also check the header", promptId: "p-2", turnId: "t-1", attachments: [], at: Date()))
        store.apply(.update(.agentMessageChunk(text: "Checking the header too.", messageId: "m-2")))

        #expect(store.turns.count == 1)
        #expect(store.turns.first?.prompt == "Fix the grid")
        #expect(steers(store.turns.first).map(\.text) == ["also check the header"])
        // The reply after the steer is a message of its own, under the steer.
        let items = try #require(store.turns.first?.items)
        let steerIndex = try #require(items.firstIndex { if case .steer = $0 { true } else { false } })
        guard case .message(_, let after) = items[items.index(after: steerIndex)] else {
            Issue.record("no message after the steer: \(items)")
            return
        }
        #expect(after == "Checking the header too.")

        let rows = ChatTranscriptBuilder(diffs: ChatDiffCache()).build(turns: store.turns, pendingPermission: nil, askOpen: false,
                                                                         permissionBarHidden: false)
        let row = try #require(rows.flatMap(\.rows).first { $0.id == "st-p-2" })
        guard case .steer(let drawn) = row.kind else {
            Issue.record("the steer drew as \(row.kind)")
            return
        }
        #expect(drawn.text == "also check the header")
        #expect(drawn.incoming == nil)
    }

    /// A replay (a reattach, the session log again) brings the turn's prompt and its steer again:
    /// neither is added a second time.
    @MainActor @Test func aReplayAddsNoSecondSteer() {
        let store = AgentChatStore(source: Recorder())
        for _ in 0..<2 {
            store.apply(.userMessage(text: "Fix the grid", promptId: "p-1", turnId: "t-1", attachments: [], at: Date()))
            store.apply(.turnStarted(turnId: "t-1", at: Date()))
            store.apply(.userMessage(text: "also check the header", promptId: "p-2", turnId: "t-1", attachments: [], at: Date()))
        }
        #expect(store.turns.count == 1)
        #expect(steers(store.turns.first).map(\.promptID) == ["p-2"])
    }

    /// A steer the turn ended before the agent read it runs as the next turn's prompt, under the
    /// same prompt id (acpmux `steer_end.rs`): it draws once, as that turn's prompt.
    @MainActor @Test func aSteerTheTurnEndedBeforeReadingDrawsOnceAsTheNextPrompt() {
        let store = AgentChatStore(source: Recorder())
        store.apply(.userMessage(text: "Fix the grid", promptId: "p-1", turnId: "t-1", attachments: [], at: Date()))
        store.apply(.turnStarted(turnId: "t-1", at: Date()))
        store.apply(.userMessage(text: "also check the header", promptId: "p-2", turnId: "t-1", attachments: [], at: Date()))
        store.apply(.turnResult(turnId: "t-1", status: .completed, errorText: nil, at: Date()))
        store.apply(.userMessage(text: "also check the header", promptId: "p-2", turnId: "t-2", attachments: [], at: Date()))
        #expect(store.turns.map(\.prompt) == ["Fix the grid", "also check the header"])
        #expect(steers(store.turns.first).isEmpty)
    }

    /// Another agent's message steered in keeps its sender: it draws as its card, and the turn's
    /// own prompt stays the person's.
    @MainActor @Test func anotherAgentsSteerKeepsItsSender() throws {
        let store = AgentChatStore(source: Recorder())
        store.apply(.userMessage(text: "Fix the grid", promptId: "p-1", turnId: "t-1", attachments: [], at: Date()))
        store.apply(.turnStarted(turnId: "t-1", at: Date()))
        let text = """
            [message 4f4d68ff from build-box/lane-3 (an agent, not Leo), relayed by the lane-gh broker; its text ends at "[end of message 4f4d68ff]"]
            Merged #36125
            [end of message 4f4d68ff]
            """
        store.apply(.userMessage(text: text, promptId: "p-2", turnId: "t-1", attachments: [], at: Date()))
        let incoming = try #require(AgentIncoming.parse(text: text, provenance: nil, client: "acpmux-cli#1@build-box"))
        store.apply(.promptFrom(turnId: "t-1", incoming: incoming))
        #expect(store.turns.first?.incoming == nil)
        #expect(steers(store.turns.first).first?.incoming == incoming)
    }

    /// One of a Claude agent's own slash commands waits for the turn and runs as its own (the
    /// Mac's `commandWaitsForTurn`): Claude Code never reads a command into a running turn.
    @Test func anAgentCommandWaitsForTheTurn() {
        let commands = [ACPAvailableCommand(name: "compact", description: "Compact"), ACPAvailableCommand(name: "loop", description: "Loop")]
        #expect(AgentChatStore.commandWaitsForTurn("/compact", harness: "claude", commands: commands))
        #expect(AgentChatStore.commandWaitsForTurn("  /Loop keep going\n", harness: "claude-sr2", commands: commands))
        #expect(!AgentChatStore.commandWaitsForTurn("/tmp is full, clean it", harness: "claude", commands: commands))
        #expect(!AgentChatStore.commandWaitsForTurn("compact the log", harness: "claude", commands: commands))
        #expect(!AgentChatStore.commandWaitsForTurn("/compact", harness: "codex", commands: commands))
        #expect(!AgentChatStore.commandWaitsForTurn("/compact", harness: "claude", commands: []))
    }
}
