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
        // What the chat says about its spilled turns stays: its title and its edits.
        #expect(store.firstPrompt == "prompt 0")
        #expect(store.hasAgentEdits)

        await store.loadEarlierFromDisk()
        #expect(store.turns.count == AgentChatStore.windowKeep + 20)
        #expect(store.turns.first?.id == "t200")
        #expect(store.isReplayed("t200"))
        while store.turnsOnDisk > 0 { await store.loadEarlierFromDisk() }
        #expect(store.turns == original)
        #expect(!store.hasEarlierHistory)
        #expect(!store.isLoadingEarlier)
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

    /// Without a spill, a chat held every turn; with the window its memory stays flat. Measured
    /// in the test process (phys_footprint): 1500 turns of 16 KB replies arriving 100 at a time,
    /// first with the window applied after each arrival as the list does at rest, then without.
    @Test func memoryStaysFlatWithTheWindow() async {
        func run(windowed: Bool) -> (growth: UInt64, held: Int) {
            let store = Self.store()
            let start = Self.footprint()
            var peak = start
            for chunk in 0..<15 {
                Self.fill(store, count: 100, replyBytes: 16_384, from: chunk * 100)
                if windowed, store.turns.count > AgentChatStore.windowTrigger { store.spillOlder(keeping: AgentChatStore.windowKeep) }
                peak = max(peak, Self.footprint())
            }
            let held = store.turns.count
            store.spill?.reset()
            return (peak &- start, held)
        }
        let after = run(windowed: true)
        let before = run(windowed: false)
        print("MEMBENCH agent-chat turns=1500 reply=16KB before=+\(before.growth >> 20)MB held=\(before.held) after=+\(after.growth >> 20)MB held=\(after.held)")
        #expect(after.held <= AgentChatStore.windowTrigger)
        #expect(before.held == 1500)
        #expect(after.growth < before.growth / 2)
    }

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
