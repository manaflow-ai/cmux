import Foundation
import Testing
@testable import CmuxNextBrowser

/// `cef.previous.log` keeps the run before this one's Chromium log, so a
/// crash's FATAL line survives the relaunch (crash-elimination.md section 4).
@Suite struct CEFProfileStorageLogTests {
    private func storage() throws -> CEFProfileStorage {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return CEFProfileStorage(root: root)
    }

    @Test func theLogMovesAsidePreviousReplaced() throws {
        let storage = try storage()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        try Data("older run\n".utf8).write(to: storage.previousLogFile)
        try Data("FATAL: last run\n".utf8).write(to: storage.logFile)
        #expect(storage.keepPreviousLog())
        #expect(!FileManager.default.fileExists(atPath: storage.logFile.path))
        #expect(try String(contentsOf: storage.previousLogFile, encoding: .utf8) == "FATAL: last run\n")
    }

    /// A first launch has no log; an earlier run's previous log stays.
    @Test func noLogKeepsThePreviousOne() throws {
        let storage = try storage()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        try Data("older run\n".utf8).write(to: storage.previousLogFile)
        #expect(!storage.keepPreviousLog())
        #expect(try String(contentsOf: storage.previousLogFile, encoding: .utf8) == "older run\n")
    }

    @Test func bothLogsSitInTheRoot() {
        let storage = CEFProfileStorage(root: URL(filePath: "/tmp/Chromium"))
        #expect(storage.logFile.path == "/tmp/Chromium/cef.log")
        #expect(storage.previousLogFile.path == "/tmp/Chromium/cef.previous.log")
    }
}
