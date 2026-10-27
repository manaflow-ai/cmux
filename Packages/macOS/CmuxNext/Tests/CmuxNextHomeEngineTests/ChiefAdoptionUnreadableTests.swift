import Foundation
import SQLite3
import Testing
@testable import CmuxNextHomeEngine

/// The SQLite error policy of the Chief home backup (p10-stability-175): a database the online
/// backup cannot read (SQLITE_CORRUPT, SQLITE_NOTADB) is cloned raw, named in `raw` and reported
/// once; the source is never moved or changed.
struct ChiefAdoptionUnreadableTests {
    private static func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cnd-adopt-unreadable-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A real database of several pages, closed (rollback journal, no sidecars).
    private static func writeDatabase(_ url: URL) throws {
        var db: OpaquePointer?
        defer { sqlite3_close_v2(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw POSIXError(.EIO)
        }
        let sql = """
        CREATE TABLE messages(id INTEGER PRIMARY KEY, body TEXT NOT NULL);
        WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 200)
        INSERT INTO messages(body) SELECT printf('%.500c', 'x') || i FROM n;
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw POSIXError(.EIO) }
    }

    private static func pageSize(_ bytes: Data) -> Int {
        let raw = Int(bytes[bytes.startIndex + 16]) << 8 | Int(bytes[bytes.startIndex + 17])
        return raw == 1 ? 65_536 : raw
    }

    /// The header keeps "SQLite format 3" (so `isSQLite` sends it to the backup), but its page-1
    /// payload fractions (bytes 21-23, always 64/32/32) are damaged: the backup's read of page 1
    /// fails with SQLITE_NOTADB.
    @Test func aDatabaseTheBackupCannotReadIsClonedRawWithOneFault() throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("home"), target = root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let database = source.appendingPathComponent("chief.sqlite3")
        try Self.writeDatabase(database)
        var bytes = try Data(contentsOf: database)
        bytes.replaceSubrange(21..<24, with: [0xff, 0xff, 0xff])
        // A later page is garbage too.
        let page = Self.pageSize(bytes)
        #expect(bytes.count >= page * 3)
        bytes.replaceSubrange(page * 2..<page * 3, with: Data(repeating: 0x5a, count: page))
        try bytes.write(to: database)
        #expect(ChiefAdoption.isSQLite(database))

        var raw: [String] = []
        var faults: [ChiefAdoption.BackupError] = []
        try ChiefAdoption.cloneTree(from: source, to: target, raw: &raw) { faults.append($0) }

        #expect(raw == [database.path])
        #expect(try Data(contentsOf: target.appendingPathComponent("chief.sqlite3")) == bytes)
        #expect(try Data(contentsOf: database) == bytes, "the source was changed")
        #expect(faults.count == 1)
        #expect(faults.first?.unreadable == true)
        #expect(faults.first?.busy == false)
    }

    /// The online backup copies pages without reading their contents, so a database with a good
    /// page 1 and a garbage later page is backed up (not raw) and reports no fault.
    @Test func aDamagedLaterPageIsBackedUpWithNoFault() throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("home"), target = root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let database = source.appendingPathComponent("chief.sqlite3")
        try Self.writeDatabase(database)
        var bytes = try Data(contentsOf: database)
        let page = Self.pageSize(bytes)
        #expect(bytes.count >= page * 3)
        bytes.replaceSubrange(page * 2..<page * 3, with: Data(repeating: 0x5a, count: page))
        try bytes.write(to: database)

        var raw: [String] = []
        var faults: [ChiefAdoption.BackupError] = []
        try ChiefAdoption.cloneTree(from: source, to: target, raw: &raw) { faults.append($0) }

        #expect(raw.isEmpty)
        #expect(faults.isEmpty)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("chief.sqlite3").path))
    }

    @Test func aGoodDatabaseIsBackedUpWithNoFault() throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("home"), target = root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Self.writeDatabase(source.appendingPathComponent("chief.sqlite3"))

        var raw: [String] = []
        var faults: [ChiefAdoption.BackupError] = []
        try ChiefAdoption.cloneTree(from: source, to: target, raw: &raw) { faults.append($0) }

        #expect(raw.isEmpty)
        #expect(faults.isEmpty)
        #expect(ChiefAdoption.isSQLite(target.appendingPathComponent("chief.sqlite3")))
    }
}
