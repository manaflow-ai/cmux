import Foundation
import SQLite3
import Testing
import CmuxNextHomeEngine

/// NIGHTLY's one-time backup of its shared Chief home (cx-is1kf.7, hq-6d 2026-10-14): the
/// conversation owner of an earlier launch usually still runs and writes `tui/`. A temp
/// NIGHTLY home (never the real ~/.cmux) with a live writer process (`/usr/bin/sqlite3`, WAL,
/// no checkpoint, still writing while the backup runs): the backup's database must open on
/// its own (read-only, immutable: no WAL beside it) with integrity ok and every row the
/// writer committed before the backup.
@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3"), "no /usr/bin/sqlite3"))
struct ChiefAdoptionLiveWriterTests {
    @Test func theBackupDatabaseOpensOnItsOwnWithTheRowsCommittedBeforeIt() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cnd-adopt-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = ChiefHome(root: root.appendingPathComponent("chief/default"), isolated: false, buildID: ChiefHome.nightlyBundleID)
        let tui = home.daemonStateDirectory
        try FileManager.default.createDirectory(at: tui, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.root.appendingPathComponent("optchat"), withIntermediateDirectories: true)
        try Data("memory".utf8).write(to: home.root.appendingPathComponent("optchat/memory.md"))
        let database = tui.appendingPathComponent("journal.sqlite3")

        // The live writer: commits 500 rows into the WAL (no checkpoint) and stays open.
        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        writer.arguments = [database.path]
        let input = Pipe(), output = Pipe()
        writer.standardInput = input
        writer.standardOutput = output
        writer.standardError = FileHandle.nullDevice
        try writer.run()
        defer {
            try? input.fileHandleForWriting.close()
            if writer.isRunning { writer.terminate() }
            writer.waitUntilExit()
        }
        func send(_ sql: String) { input.fileHandleForWriting.write(Data((sql + "\n").utf8)) }
        send("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        send("CREATE TABLE messages(id INTEGER PRIMARY KEY, body TEXT NOT NULL);")
        send("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 500) INSERT INTO messages(body) SELECT 'before ' || i FROM n;")
        send("SELECT 'ready';")
        let ready = try Self.readUntil("ready", from: output.fileHandleForReading)
        #expect(ready, "the writer did not commit its rows")
        // Still writing while the backup runs.
        for batch in 0..<50 {
            send("INSERT INTO messages(body) VALUES ('during \(batch)');")
        }

        let outcome = try ChiefAdoption(home: home).run(by: ChiefHome.nightlyBundleID)
        guard case .adopted(let backup?) = outcome else {
            Issue.record("no backup: \(outcome)")
            return
        }
        let copy = backup.appendingPathComponent("tui/journal.sqlite3")
        var db: OpaquePointer?
        defer { sqlite3_close_v2(db) }
        let opened = sqlite3_open_v2("file:\(copy.path)?immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        #expect(opened == SQLITE_OK)
        #expect(Self.text(db, "PRAGMA integrity_check") == "ok")
        #expect(Self.text(db, "SELECT count(*) FROM messages WHERE body LIKE 'before %'") == "500",
                "the backup lost rows committed before it")
        // The rest of the home is cloned as before.
        #expect(FileManager.default.contents(atPath: backup.appendingPathComponent("optchat/memory.md").path) == Data("memory".utf8))
    }

    /// The first column of the first row of `sql`, or nil.
    private static func text(_ db: OpaquePointer?, _ sql: String) -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    /// Reads lines until one equals `marker` (true) or the writer's output ends (false).
    private static func readUntil(_ marker: String, from handle: FileHandle) throws -> Bool {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return false }
            buffer.append(chunk)
            if String(decoding: buffer, as: UTF8.self).split(separator: "\n").contains(where: { $0 == marker }) { return true }
        }
    }
}
