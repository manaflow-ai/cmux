import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// A chat no list shows keeps the same window of turns in memory as the one on screen, and a
/// memory warning reaches it (Leo, 2026-11-14: "I want us to also look at if we can decrease
/// battery drain/ram on iOS app and cc aziz too"). Before, `AgentSessionDirectory` kept one
/// store per agent tab ever touched (the chat, Home, Feed cards), and only the store on screen
/// spilled turns to disk (`ChatTranscriptList.spillIfResting`): an agent that kept working
/// while the person was elsewhere grew its store without a bound, and `MemoryPressure` never
/// reached it.
@MainActor
@Suite(.serialized) struct AgentChatOffScreenMemoryTests {
    final class Source: AgentSessionSource {
        let summary: AgentSessionSummary
        init(summary: AgentSessionSummary) { self.summary = summary }
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    static func summary(_ index: Int) -> AgentSessionSummary {
        AgentSessionSummary(id: "s\(index)", name: "S\(index)", harness: "claude", agentName: "Claude",
                            cwd: "~", workspaceTitle: "w", macName: "m")
    }

    /// Bytes of reply text the store holds in memory.
    static func heldReplyBytes(_ store: AgentChatStore) -> Int {
        store.turns.reduce(0) { total, turn in
            total + turn.items.reduce(0) { sum, item in
                if case .message(_, let markdown) = item { return sum + markdown.utf8.count }
                return sum
            }
        }
    }

    /// 50 agent tabs touched (Home and Feed cards make their stores), one of them working off
    /// screen through 5,000 turns of 1 KB replies, one turn per arrival as a live agent sends
    /// them. Its store holds at most the list's window; the rest is on disk, and a memory
    /// warning brings it down to the warning's floor. Every turn reads back, in order.
    @Test func anOffScreenChatKeepsTheWindowAndAWarningReachesIt() async {
        let directory = AgentSessionDirectory()
        directory.makeSource = { Source(summary: $0) }
        let stores = (0..<50).map { directory.store(for: Self.summary($0)) }
        let chat = stores[7]
        let folder = FileManager.default.temporaryDirectory.appending(path: "agentspill-offscreen-\(UUID().uuidString)")
        chat.makeSpill = { RowSpill(directory: folder, pageSize: 20, maxRows: 100_000) }
        defer { chat.spill?.reset() }

        for index in 0..<5000 { AgentChatSpillTests.fill(chat, count: 1, replyBytes: 1024, from: index) }
        print("offscreen-chat: turns in memory \(chat.turns.count), reply bytes in memory \(Self.heldReplyBytes(chat)), turns on disk \(chat.turnsOnDisk)")
        #expect(chat.turns.count <= AgentChatStore.windowTrigger, "an off-screen chat keeps the on-screen window")
        #expect(chat.turns.count + chat.turnsOnDisk == 5000, "no turn is lost: the rest is on disk")
        #expect(Self.heldReplyBytes(chat) <= AgentChatStore.windowTrigger * 1100)
        #expect(chat.hasEarlierHistory)
        #expect(chat.firstPrompt == "prompt 0")

        MemoryPressure.shared.relieve()
        print("offscreen-chat: after a memory warning turns in memory \(chat.turns.count), reply bytes in memory \(Self.heldReplyBytes(chat))")
        #expect(chat.turns.count == AgentChatStore.pressureKeep, "a memory warning reaches the off-screen chat")
        #expect(chat.turns.last?.id == "t4999")

        // Re-opened, the chat reads back from disk as the on-screen one does: every turn, in order.
        while chat.turnsOnDisk > 0 { await chat.loadEarlierFromDisk() }
        #expect(chat.turns.map(\.id) == (0..<5000).map { "t\($0)" })
    }
}
