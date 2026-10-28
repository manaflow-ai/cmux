import CmuxNextCompat
@testable import CmuxNextHistory
import Foundation
import Testing

/// `memorySqliteTrim`: a history SQLite connection gives its page cache back on its
/// owner, and the visit log follows the memory coordinator's limits.
@Suite struct HistorySQLiteTrimTests {
    private static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "HistorySQLiteTrim-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func total(_ db: HistorySQLite) throws -> Int64 {
        var total: Int64 = 0
        try db.run("SELECT SUM(LENGTH(text)) FROM rows") { total = $0.integer(0) }
        return total
    }

    /// After a 10k-row query the cache holds about 1 MB; a release brings it near 0, and the rows
    /// read again.
    @Test func aReleaseFreesThePageCacheA10kRowQueryFilled() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try HistorySQLite(url: root.appending(path: "trim.sqlite"))
        try db.execute("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE rows(id INTEGER PRIMARY KEY, text TEXT NOT NULL);
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 10000)
            INSERT INTO rows(text) SELECT printf('%0100d', i) FROM n;
            """)
        // Read until the cache holds the rows: a connection another test closes may evict pages of
        // this one where SQLite shares one page cache LRU between connections.
        var filled = 0
        for _ in 0..<5 where filled <= 500_000 {
            #expect(try Self.total(db) == 1_000_000)
            filled = try #require(db.cacheUsedBytes)
        }
        #expect(filled > 500_000, "the scan filled \(filled) bytes")

        db.releaseMemory()
        let trimmed = try #require(db.cacheUsedBytes)
        #expect(trimmed < 32 * 1024, "release left \(trimmed) of \(filled) bytes")
        #expect(try Self.total(db) == 1_000_000)
    }

    /// The log's consumer calls run on its actor: a release below 100 % frees the cache a query
    /// filled, a release at 100 % frees nothing, and the visits read again.
    @Test func theVisitLogReleasesItsCacheBelowTheDefaultLimit() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = BrowserVisitLog(url: root.appending(path: "History.sqlite"))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<2_000 {
            await log.record(url: "https://example.com/\(index)/" + String(repeating: "p", count: 200),
                             title: String(repeating: "t", count: 100), tab: nil,
                             at: start.addingTimeInterval(TimeInterval(index)))
        }
        var filled = 0
        for _ in 0..<5 where filled <= 128 * 1024 {
            #expect(await log.visits(limit: 2_000).count == 2_000)
            filled = try #require(await log.memoryUsage).footprintBytes
        }
        #expect(filled > 128 * 1024, "the query filled \(filled) bytes")

        let kept = try #require(await log.releaseMemory(downTo: .default)).footprintBytes
        #expect(kept > 128 * 1024, "100 % releases nothing: \(kept) of \(filled) bytes")

        let trimmed = try #require(await log.releaseMemory(downTo: .criticalThreshold)).footprintBytes
        #expect(trimmed < 32 * 1024, "critical left \(trimmed) of \(filled) bytes")
        #expect(await log.visits(limit: 2_000).count == 2_000)
        _ = await log.updateMemoryLimit(.default)
    }

    /// A log that never opened reports nothing and stays closed: no file appears.
    @Test func anUnopenedLogStaysClosed() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "History.sqlite")
        let log = BrowserVisitLog(url: url)
        #expect(await log.releaseMemory(downTo: .criticalThreshold) == .empty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// The cap scales with the limit and never goes under the working set.
    @Test func theCacheCapScalesWithTheLimit() {
        #expect(BrowserVisitLog.cacheKiB(at: .default) == HistorySQLite.defaultCacheKiB)
        #expect(BrowserVisitLog.cacheKiB(at: MemoryLimit(percent: 25)) == 500)
        #expect(BrowserVisitLog.cacheKiB(at: .criticalThreshold) == BrowserVisitLog.workingSetCacheKiB)
    }
}
