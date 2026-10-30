import Foundation
import Testing
@testable import CmuxNextAgentPane

/// An unreadable prompt journal is set aside beside itself, never written over (cmux#27963 review).
struct AgentPanePromptJournalSetAsideTests {
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
