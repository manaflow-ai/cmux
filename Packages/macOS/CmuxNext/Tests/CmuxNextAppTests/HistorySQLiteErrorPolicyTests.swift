import Foundation
@testable import CmuxNextHistory
import Testing

/// The SQLite error policy of the history stores (p10-stability-175): a file SQLite reports
/// corrupt or not a database is moved aside to `<name>.corrupt` with its sidecars, a new database
/// opens in its place and one fault is reported; a good file is never touched.
struct HistorySQLiteErrorPolicyTests {
    private static func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cnd-history-sqlite-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aGarbageFileOpensAsANewDatabaseWithOneFault() throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("History.sqlite")
        let garbage = Data(repeating: 0x5a, count: 8192)
        try garbage.write(to: url)
        var faults: [HistorySQLite.SetAside] = []

        let db = try HistorySQLite(url: url) { faults.append($0) }
        try db.execute("CREATE TABLE t(v TEXT); INSERT INTO t VALUES ('kept')")
        var count = 0
        try db.run("SELECT COUNT(*) FROM t") { count = Int($0.integer(0)) }

        #expect(count == 1)
        #expect(faults.count == 1)
        let aside = root.appendingPathComponent("History.sqlite.corrupt")
        #expect(faults.first?.aside.standardizedFileURL == aside.standardizedFileURL)
        #expect(try Data(contentsOf: aside) == garbage)
    }

    @Test func aGoodFileIsKeptAndReportsNoFault() throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("History.sqlite")
        var faults: [HistorySQLite.SetAside] = []
        do {
            let db = try HistorySQLite(url: url) { faults.append($0) }
            try db.execute("CREATE TABLE t(v TEXT); INSERT INTO t VALUES ('kept')")
        }

        let db = try HistorySQLite(url: url) { faults.append($0) }
        var count = 0
        try db.run("SELECT COUNT(*) FROM t") { count = Int($0.integer(0)) }

        #expect(count == 1)
        #expect(faults.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path + ".corrupt"))
    }

    /// The visit log on a garbage file records and reads again instead of failing every call.
    @Test func theVisitLogRecordsIntoANewFileAfterAGarbageOne() async throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("History.sqlite")
        try Data(repeating: 0xa5, count: 4096).write(to: url)
        let log = BrowserVisitLog(url: url)

        await log.record(url: "https://example.com/", title: "Example", tab: nil, at: Date())

        #expect(await log.count() == 1)
        #expect(FileManager.default.fileExists(atPath: url.path + ".corrupt"))
    }
}
