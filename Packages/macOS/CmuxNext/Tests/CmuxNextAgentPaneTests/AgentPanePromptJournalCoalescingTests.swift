import Foundation
import Testing
@testable import CmuxNextAgentPane

/// hq#8747 (disk writes): acpmux's acknowledgements forget prompts in bursts, and each forget was a
/// whole-file atomic write on the thread that delivered the reply. They now share one coalesced
/// write; a prompt's record stays on disk before it returns, and a forget never undoes a newer one.
struct AgentPanePromptJournalCoalescingTests {
    private func journal() throws -> (AgentPanePromptJournal, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "prompt-journal-coalescing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (AgentPanePromptJournal(url: directory.appending(path: "prompt-journal.json")), directory)
    }

    private func entry(_ promptId: String) -> AgentPanePromptJournal.Entry {
        AgentPanePromptJournal.Entry(daemon: "d", sessionId: "s", promptId: promptId, params: "{}", at: Date())
    }

    private func onDisk(_ url: URL) throws -> [String] {
        try AgentPanePromptJournal(url: url).entries().map(\.promptId)
    }

    @Test func aThousandForgetsShareAFewDiskWrites() async throws {
        let (journal, directory) = try journal()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = UUID()
        for index in 0..<1_000 { #expect(journal.record(entry("p\(index)"), owner: owner)) }
        // Records are durable, never through the coalescing writer.
        #expect(journal.writer.diskWrites == 0)

        for index in 0..<1_000 { journal.forget(daemon: "d", promptId: "p\(index)") }
        await journal.settle()
        let writes = journal.writer.diskWrites
        print("AgentPanePromptJournalCoalescingTests: 1000 forgets: \(writes) disk write(s) (before: 1000)")
        #expect(writes <= 5)
        #expect(try onDisk(journal.url).isEmpty)
    }

    @Test func aRecordAfterAPendingForgetStaysOnDisk() async throws {
        let (journal, directory) = try journal()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = UUID()
        #expect(journal.record(entry("a"), owner: owner))
        journal.forget(daemon: "d", promptId: "a")
        // The same promptId again, before the forget's write ran: durable now, and the older
        // coalesced write must not land over it.
        #expect(journal.record(entry("a"), owner: owner))
        #expect(try onDisk(journal.url) == ["a"])
        await journal.settle()
        #expect(try onDisk(journal.url) == ["a"])
    }
}
