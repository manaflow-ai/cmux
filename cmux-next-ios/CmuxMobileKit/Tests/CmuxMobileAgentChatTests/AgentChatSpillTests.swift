import CmuxMobileModel
import Darwin
import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// A long agent chat keeps a window of turns in memory: older turns wait on disk while the app
/// runs, come back in order when the reader scrolls up, and a memory warning gives memory back
/// (the user, 2026-11-05: "make sure that all rows aren't loaded in memory unbounded and that
/// some are kept on disk during app usage"). Before, `turns` held every turn the chat ever
/// loaded for as long as it was open.
@MainActor
@Suite(.serialized) struct AgentChatSpillTests {
    final class Source: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m")
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    static func store() -> AgentChatStore {
        let store = AgentChatStore(source: Source())
        let directory = FileManager.default.temporaryDirectory.appending(path: "agentspill-\(UUID().uuidString)")
        store.makeSpill = { RowSpill(directory: directory, pageSize: 20, maxRows: 100_000) }
        return store
    }

    /// `count` ended turns, each with a reply of `replyBytes` and an edit.
    static func fill(_ store: AgentChatStore, count: Int, replyBytes: Int = 64, from first: Int = 0) {
        let at = Date(timeIntervalSince1970: 1_000_000)
        var events: [AgentSessionEvent] = []
        for index in first..<(first + count) {
            let turn = "t\(index)"
            events.append(.userMessage(text: "prompt \(index)", promptId: "p\(index)", turnId: turn, attachments: [], at: at))
            events.append(.turnStarted(turnId: turn, at: at))
            events.append(.update(.agentMessageChunk(text: "reply \(index) " + String(repeating: "x", count: replyBytes), messageId: "m\(index)")))
            if index == 3 {
                var call = ACPToolCall(id: "c\(index)", title: "Edit", kind: .edit, status: .completed,
                                       content: [.diff(path: "a.swift", oldText: "a", newText: "b")])
                call.startedAt = at
                events.append(.update(.toolCall(call)))
            }
            events.append(.turnResult(turnId: turn, status: .completed, errorText: nil, at: at))
        }
        store.apply(.batch(events))
    }

    @Test func olderTurnsSpillAndComeBackInOrder() async {
        let store = Self.store()
        Self.fill(store, count: 300)
        let original = store.turns
        #expect(store.firstPrompt == "prompt 0")
        #expect(store.hasAgentEdits)
        #expect(!store.hasEarlierHistory)

        #expect(store.spillOlder(keeping: AgentChatStore.windowKeep) == 220)
        #expect(store.turns.count == AgentChatStore.windowKeep)
        #expect(store.turns.first?.id == "t220")
        #expect(store.turnsOnDisk == 220)
        #expect(store.hasEarlierHistory)
        // The untitled chat keeps its title from its first turn, on disk.
        #expect(store.firstPrompt == "prompt 0")

        await store.loadEarlierFromDisk()
        #expect(store.turns.count == AgentChatStore.windowKeep + 20)
        #expect(store.turns.first?.id == "t200")
        #expect(store.isReplayed("t200"))
        while store.turnsOnDisk > 0 { await store.loadEarlierFromDisk() }
        #expect(store.turns == original)
        #expect(!store.hasEarlierHistory)
        #expect(!store.isLoadingEarlier)
    }

    /// A source that replays its whole log (a reattach, the mock and polish sources) brings
    /// turns that are on disk again: they are not added at the bottom, and their records do
    /// not land in the newest turn.
    @Test func aReplayOfSpilledTurnsChangesNothing() async {
        let store = Self.store()
        Self.fill(store, count: 200)
        store.spillOlder(keeping: 50)
        let shown = store.turns
        // The replay of the turns on disk (t0 to t149).
        Self.fill(store, count: 150)
        #expect(store.turns == shown)
        while store.turnsOnDisk > 0 { await store.loadEarlierFromDisk() }
        #expect(store.turns.map(\.id) == (0..<200).map { "t\($0)" })
    }

    /// No spill while a page is on its way: it would put newer turns on disk below the page.
    @Test func noSpillWhileAPageLoads() {
        let store = Self.store()
        Self.fill(store, count: 200)
        store.apply(.earlierHistory(true))
        store.loadEarlier()
        #expect(store.isLoadingEarlier)
        #expect(store.spillOlder(keeping: 10) == 0)
    }

    /// Edit and Resend of the oldest turn in memory forks through the newest turn on disk.
    @Test func forkOfTheOldestTurnInMemoryUsesTheSpilledOne() {
        let store = AgentChatStore(source: ForkSource())
        let directory = FileManager.default.temporaryDirectory.appending(path: "agentspill-\(UUID().uuidString)")
        store.makeSpill = { RowSpill(directory: directory, pageSize: 20, maxRows: 100_000) }
        Self.fill(store, count: 30)
        for index in 0..<30 { store.apply(.turnSeq(turnId: "t\(index)", seq: 100 + index)) }
        store.spillOlder(keeping: 10)
        let oldest = store.turns[0]
        #expect(oldest.id == "t20")
        #expect(store.editForkSeq(for: oldest) == 119)
        store.spill?.reset()
    }

    final class ForkSource: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m")
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    /// A running turn, an open ask and the turn the reader is on never leave memory.
    @Test func liveAndReadTurnsStay() {
        let store = Self.store()
        Self.fill(store, count: 50)
        // The reader is on turn 10: it and every turn after it stay.
        #expect(store.spillOlder(keeping: 5, protecting: "t10") == 10)
        #expect(store.turns.first?.id == "t10")
        let at = Date(timeIntervalSince1970: 1_000_000)
        store.apply(.userMessage(text: "still going", promptId: "px", turnId: "tx", attachments: [], at: at))
        store.apply(.turnStarted(turnId: "tx", at: at))
        for index in 0..<10 {
            store.apply(.userMessage(text: "queued \(index)", promptId: "py\(index)", turnId: "ty\(index)", attachments: [], at: at))
        }
        store.spillOlder(keeping: 1)
        #expect(store.turns.first?.id == "tx")
    }

    /// Without a spill, a chat held every turn; with the window its memory stays flat. 1000
    /// turns of 16 KB replies arrive 100 at a time, with the window applied after each arrival
    /// as the list does at rest, then without. Measured as live heap bytes (malloc's size in
    /// use, with the store alive), which allocator reuse between the runs does not skew.
    @Test func memoryStaysFlatWithTheWindow() async {
        func run(windowed: Bool) -> (live: Int, held: Int) {
            let store = Self.store()
            let start = Self.heapInUse()
            for chunk in 0..<10 {
                Self.fill(store, count: 100, replyBytes: 16_384, from: chunk * 100)
                if windowed, store.turns.count > AgentChatStore.windowTrigger { store.spillOlder(keeping: AgentChatStore.windowKeep) }
            }
            store.spill?.flush()
            let live = Self.heapInUse() - start
            let held = store.turns.count
            store.spill?.reset()
            return (live, held)
        }
        let before = run(windowed: false)
        let after = run(windowed: true)
        let line = "MEMBENCH agent-chat turns=1000 reply=16KB before=\(before.live >> 10)KB held=\(before.held) after=\(after.live >> 10)KB held=\(after.held)"
        print(line)
        Attachment.record(line, named: "membench.txt")
        #expect(after.held <= AgentChatStore.windowTrigger)
        #expect(before.held == 1000)
        #expect(after.live < before.live / 4)
    }

    /// Bytes malloc holds for live allocations, in every zone.
    static func heapInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

}
