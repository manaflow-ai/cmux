import Foundation
import Testing
@testable import CmuxNextAgentPane

/// An unreadable prompt journal is set aside beside itself, never written over (cmux#27963 review).
struct AgentPanePromptJournalSetAsideTests {
    /// Inject the failure instead of chmod: root can read mode-000 files, and the directory
    /// remains writable so the old implementation would successfully replace the original.
    @Test func aReadFailureRefusesWritesAndPreservesTheOriginal() throws {
        for code in [CocoaError.Code.fileReadNoPermission, .fileReadUnknown] {
            let directory = try Self.makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appending(path: "prompts.json")
            let original = Data("{\"version\":2,\"entries\":[],\"pendingTrust\":[]}".utf8)
            try original.write(to: url)
            let journal = AgentPanePromptJournal(url: url, readFile: { _ in
                throw CocoaError(code)
            })

            #expect(journal.entries().isEmpty)
            #expect(!journal.recordPendingTrust(daemon: "daemon", folder: "/first"))
            #expect(try Data(contentsOf: url) == original)
            // Refusal survives the one-time load: another mutation must not overwrite it either.
            #expect(!journal.recordPendingTrust(daemon: "daemon", folder: "/second"))
            #expect(try Data(contentsOf: url) == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["prompts.json"])
        }
    }

    @Test func aMissingJournalStillAllowsTheFirstWrite() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "prompts.json")
        let journal = AgentPanePromptJournal(url: url, readFile: { _ in
            throw CocoaError(.fileReadNoSuchFile)
        })

        #expect(journal.recordPendingTrust(daemon: "daemon", folder: "/first"))
        let reopened = AgentPanePromptJournal(url: url)
        #expect(reopened.pendingTrustFolders(daemon: "daemon") == ["/first"])
    }

    /// Two unreadable prompt journals found in one second are both kept: before, the second move
    /// found the first's name taken, failed silently, and the next write replaced the file.
    @Test func twoUnreadableJournalsInOneSecondAreBothKept() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "prompts.json")
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        try Data("{\"first".utf8).write(to: url)
        #expect(AgentPanePromptJournal(url: url, now: { now }).entries().isEmpty)
        try Data("{\"second".utf8).write(to: url)
        #expect(AgentPanePromptJournal(url: url, now: { now }).entries().isEmpty)

        let kept = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains("unreadable") }.map { try Data(contentsOf: directory.appending(path: $0)) }
        #expect(Set(kept) == [Data("{\"first".utf8), Data("{\"second".utf8)])
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "prompt-journal-aside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
