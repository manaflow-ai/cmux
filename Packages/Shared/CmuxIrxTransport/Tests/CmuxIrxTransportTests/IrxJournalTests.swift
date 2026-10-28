import Foundation
import Testing

@testable import CmuxIrxTransport

@Suite struct IrxJournalTests {
    @Test func endpointIDsAreRedactedBeforeRetentionAndRendering() throws {
        let endpoint = V2IdentityKey().endpointID
        let dir = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("irx-private-journal")
        let journal = IrxJournal(subsystem: "dev.cmux.tests", category: "privacy", journalFileURL: file)
        journal.record("endpoint", "bound", ["endpoint_id": endpoint, "error": "peer \(endpoint) closed", "generation": "3"])
        let event = try #require(journal.tail().first)
        #expect(!event.attributes.values.contains { $0.contains(endpoint) })
        #expect(!IrxJournal.render(event).contains(endpoint))
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains(endpoint))
        #expect(event.attributes["generation"] == "3")
        let external = IrxJournalEvent(wallTime: Date(), monotonicMs: 0, component: "endpoint", event: "bound",
            attributes: ["endpoint_id": endpoint.uppercased()])
        #expect(!IrxJournal.render(external).contains(endpoint.uppercased()))
    }

    @Test func terminalTraceEventsAreRateLimitedBeforeRetention() {
        let journal = IrxJournal(subsystem: "dev.cmux.tests", category: "terminal-trace")

        for index in 0...120 {
            journal.record(
                "terminal-trace",
                "phase-\(index)",
                ["trace_id": "0000000000000001"]
            )
        }

        #expect(journal.tail(200).count == 120)
        #expect(journal.counterSnapshot()["terminal_trace_dropped"] == 1)
    }

    /// A private directory of this user for one test (0700, removed after).
    private static func privateDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("irx-journal-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return dir
    }

    @Test func theJournalFileIsReadableOnlyByItsOwner() throws {
        let dir = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("journal.jsonl")
        let journal = IrxJournal(subsystem: "dev.cmux.tests", category: "mode", journalFileURL: file)
        journal.record("next-host", "started", ["session": "s1"])
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
        #expect(mode & 0o077 == 0, "journal mode \(String(mode, radix: 8)) lets other users read it")
    }

    @Test func anExistingSharedJournalBecomesPrivate() throws {
        let dir = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("journal.jsonl")
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data(), attributes: [.posixPermissions: 0o644]))
        let journal = IrxJournal(subsystem: "dev.cmux.tests", category: "mode", journalFileURL: file)
        journal.record("next-host", "started", [:])
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
        #expect(mode & 0o077 == 0)
    }

    @Test func theJournalNeverWritesThroughASymlink() throws {
        let dir = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("elsewhere.txt")
        try Data("keep\n".utf8).write(to: target)
        let file = dir.appendingPathComponent("journal.jsonl")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let journal = IrxJournal(subsystem: "dev.cmux.tests", category: "symlink", journalFileURL: file)
        journal.record("next-host", "started", ["session": "s1"])
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep\n")
        // Still journals in memory.
        #expect(journal.tail().count == 1)
    }

    @Test func theJournalNeverWritesThroughAHardLink() throws {
        let dir = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("elsewhere.txt")
        try Data("keep\n".utf8).write(to: target)
        let file = dir.appendingPathComponent("journal.jsonl")
        try FileManager.default.linkItem(at: target, to: file)
        let journal = IrxJournal(subsystem: "dev.cmux.tests", category: "hardlink", journalFileURL: file)
        journal.record("next-host", "started", [:])
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep\n")
    }

    @Test func aJournalInADirectoryOtherUsersCanWriteIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("irx-journal-shared-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A sticky, world-writable directory, as /tmp is.
        try FileManager.default.setAttributes([.posixPermissions: 0o1777], ofItemAtPath: dir.path)
        let file = dir.appendingPathComponent("journal.jsonl")
        let journal = IrxJournal(subsystem: "dev.cmux.tests", category: "shared-dir", journalFileURL: file)
        journal.record("next-host", "started", [:])
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(journal.fileURL == nil)
    }

    @Test func aJournalReopensAndAppends() throws {
        let dir = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("journal.jsonl")
        IrxJournal(subsystem: "dev.cmux.tests", category: "reopen", journalFileURL: file).record("a", "one", [:])
        IrxJournal(subsystem: "dev.cmux.tests", category: "reopen", journalFileURL: file).record("a", "two", [:])
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
    }
}
