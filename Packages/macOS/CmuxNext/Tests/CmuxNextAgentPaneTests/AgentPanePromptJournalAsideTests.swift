import Foundation
import Testing
@testable import CmuxNextAgentPane

/// cmux#28204 review: an unreadable prompt journal is set aside before anything is written, and a
/// set aside that fails keeps it in place: no write replaces the only copy of prompts acpmux never
/// acknowledged. The next write tries the move again.
struct AgentPanePromptJournalAsideTests {
    @Test func anUnreadableJournalThatCannotBeSetAsideIsNeverOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "prompt-journal-aside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "prompt-journal.json")
        let corrupt = Data("{\"entries\": [{\"promptId\": \"half a pro".utf8)
        try corrupt.write(to: url)
        let stamp = Date(timeIntervalSince1970: 1_000)
        let aside = directory.appending(path: "prompt-journal.unreadable-1000.json")
        // Something already at the set-aside name: the move fails.
        try FileManager.default.createDirectory(at: aside.appending(path: "blocker"), withIntermediateDirectories: true)

        let journal = AgentPanePromptJournal(url: url, now: { stamp })
        #expect(!journal.recordPendingTrust(daemon: "d", folder: "/tmp/one"), "a write over the unreadable journal")
        #expect(try Data(contentsOf: url) == corrupt)

        // The way is clear: the next write sets the journal aside first, then writes.
        try FileManager.default.removeItem(at: aside)
        #expect(journal.recordPendingTrust(daemon: "d", folder: "/tmp/two"))
        #expect(try Data(contentsOf: aside) == corrupt)
        #expect(try Data(contentsOf: url) != corrupt)
    }
}
