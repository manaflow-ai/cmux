public import Foundation
import SQLite3
import os

private let syncStoreLog = Logger(subsystem: "com.cmuxterm.app", category: "CmuxSyncStore")

/// Local-first sync store: one raw-SQLite3 database backing the generic sync
/// substrate (DESIGN.md §4). This is a deliberate clone of
/// ``MobilePairedMacStore``'s pattern — an `actor` serializing a
/// `SQLITE_OPEN_FULLMUTEX` connection, `PRAGMA user_version` lazy migrations, a
/// `BindValue` binder — extended to one generic `sync_records` table keyed by
/// `(team_id, collection, record_id)` plus a `sync_cursors` table. Typed facades
/// (e.g. ``DeviceSyncFacade``) read/write through it; the store stays generic.
public actor CmuxSyncStore: CmuxSyncStoring {
    public static let currentSchemaVersion: Int32 = 1

    private let dbPath: String
    // `nonisolated(unsafe)` only so the nonisolated `deinit` can close the
    // handle; every other access is actor-isolated and the connection is
    // FULLMUTEX, matching MobilePairedMacStore.
    nonisolated(unsafe) private var db: OpaquePointer?

    /// The default on-disk location, `cmux-sync.sqlite3` next to the paired-Mac
    /// db under Application Support/cmux.
    public static func defaultDatabaseURL(fileManager: FileManager = .default) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("cmux", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("cmux-sync.sqlite3")
    }

    public init(databaseURL: URL) throws {
        self.dbPath = databaseURL.path
        self.db = try Self.openConnection(path: databaseURL.path)
    }

    public init() throws {
        try self.init(databaseURL: Self.defaultDatabaseURL())
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: - Open + migrate

    private nonisolated static func openConnection(path: String) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw CmuxSyncStoreError.openFailed(rc)
        }
        for pragma in ["PRAGMA foreign_keys = ON;", "PRAGMA journal_mode = WAL;"] {
            let prc = sqlite3_exec(handle, pragma, nil, nil, nil)
            guard prc == SQLITE_OK else {
                sqlite3_close_v2(handle)
                throw CmuxSyncStoreError.stepFailed(prc, "")
            }
        }
        return handle
    }

    private var didMigrate = false

    private func ensureReady() throws {
        guard !didMigrate else { return }
        try runMigrations()
        didMigrate = true
    }

    private func runMigrations() throws {
        let version = try userVersion()
        switch version {
        case 0:
            try migrateToV1()
            try setUserVersion(1)
            fallthrough
        case 1:
            break
        default:
            throw CmuxSyncStoreError.unknownSchemaVersion(Int(version))
        }
    }

    private func migrateToV1() throws {
        // One row per synced record across all collections; payload opaque JSON.
        try exec("""
            CREATE TABLE IF NOT EXISTS sync_records (
                team_id     TEXT    NOT NULL,
                collection  TEXT    NOT NULL,
                record_id   TEXT    NOT NULL,
                rev         INTEGER NOT NULL,
                updated_at  REAL    NOT NULL,
                sort_key    REAL    NOT NULL DEFAULT 0,
                deleted     INTEGER NOT NULL DEFAULT 0,
                payload     TEXT    NOT NULL,
                PRIMARY KEY (team_id, collection, record_id)
            );
        """)
        // Drives the launch query: live records of a collection in render order.
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_sync_records_render
              ON sync_records (team_id, collection, deleted, sort_key);
        """)
        // One row per (team, collection): the durable cursor watermark.
        try exec("""
            CREATE TABLE IF NOT EXISTS sync_cursors (
                team_id     TEXT    NOT NULL,
                collection  TEXT    NOT NULL,
                cursor_rev  INTEGER NOT NULL DEFAULT 0,
                synced_at   REAL    NOT NULL DEFAULT 0,
                PRIMARY KEY (team_id, collection)
            );
        """)
        // Idempotency markers for the one-time transparent migration per account.
        try exec("""
            CREATE TABLE IF NOT EXISTS sync_meta (
                key   TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );
        """)
    }

    // MARK: - Reads

    public func liveRecords(teamID: String, collection: String) throws -> [StoredSyncRecord] {
        try ensureReady()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            SELECT record_id, rev, updated_at, sort_key, deleted, payload
            FROM sync_records
            WHERE team_id = ? AND collection = ? AND deleted = 0
            ORDER BY sort_key DESC;
        """
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw CmuxSyncStoreError.prepareFailed(rc, lastErrorMessage())
        }
        try bind(statement: statement, parameters: [.text(teamID), .text(collection)])
        var out: [StoredSyncRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            out.append(readRecord(statement, teamID: teamID, collection: collection))
        }
        return out
    }

    public func cursor(teamID: String, collection: String) throws -> Int {
        try ensureReady()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT cursor_rev FROM sync_cursors WHERE team_id = ? AND collection = ?;"
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw CmuxSyncStoreError.prepareFailed(rc, lastErrorMessage())
        }
        try bind(statement: statement, parameters: [.text(teamID), .text(collection)])
        if sqlite3_step(statement) == SQLITE_ROW {
            return Int(sqlite3_column_int64(statement, 0))
        }
        return 0
    }

    // MARK: - Frame application (atomic per frame, DESIGN.md §3.2)

    public func applyDelta(
        teamID: String,
        collection: String,
        frameRev: Int,
        records: [SyncWireRecord],
        sortKeyFor: @Sendable (SyncWireRecord) -> Double,
        now: Date
    ) throws {
        try ensureReady()
        try transaction {
            for record in records {
                try applyOneRecord(teamID: teamID, collection: collection, record: record, sortKey: sortKeyFor(record))
            }
            // The cursor advances to the frame head only after every record in
            // the frame committed (the all-or-nothing rule). Monotone.
            try setCursor(teamID: teamID, collection: collection, to: frameRev, now: now)
        }
    }

    public func applySnapshot(
        teamID: String,
        collection: String,
        snapshotRev: Int,
        records: [SyncWireRecord],
        sortKeyFor: @Sendable (SyncWireRecord) -> Double,
        now: Date
    ) throws {
        try ensureReady()
        try transaction {
            var present = Set<String>()
            for record in records {
                try applyOneRecord(teamID: teamID, collection: collection, record: record, sortKey: sortKeyFor(record))
                present.insert(record.id)
            }
            // Missing-record reconciliation, scoped to authoritative records
            // (rev >= 1): drop any local record in [1, snapshotRev] not in the
            // snapshot — it was deleted while we were disconnected. Provisional
            // rev == 0 migration rows are EXEMPT and survive (DESIGN.md §3.2a/§6).
            let existing = try allRecordIDs(teamID: teamID, collection: collection, minRev: 1, maxRev: snapshotRev)
            for id in existing where !present.contains(id) {
                try deleteRecord(teamID: teamID, collection: collection, recordID: id)
            }
            try setCursor(teamID: teamID, collection: collection, to: snapshotRev, now: now)
        }
    }

    /// Apply one wire record under the monotone `local.rev >= r.rev` guard. A
    /// stale or duplicate record (rev not newer) is ignored; a tombstone is
    /// written as a deleted row; a live record upserts. (DESIGN.md §3.2)
    private func applyOneRecord(teamID: String, collection: String, record: SyncWireRecord, sortKey: Double) throws {
        if let localRev = try recordRev(teamID: teamID, collection: collection, recordID: record.id),
           localRev >= record.rev {
            return // stale or duplicate; keep the higher rev we already have
        }
        // Wire updatedAt is epoch ms; the column is epoch seconds. This /1000 is
        // the single documented unit boundary (DESIGN.md §4.1).
        let updatedAtSeconds = record.updatedAt / 1000.0
        try exec("""
            INSERT INTO sync_records (team_id, collection, record_id, rev, updated_at, sort_key, deleted, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(team_id, collection, record_id) DO UPDATE SET
                rev = excluded.rev,
                updated_at = excluded.updated_at,
                sort_key = excluded.sort_key,
                deleted = excluded.deleted,
                payload = excluded.payload;
        """, binding: [
            .text(teamID),
            .text(collection),
            .text(record.id),
            .int(Int64(record.rev)),
            .real(updatedAtSeconds),
            .real(sortKey),
            .int(record.deleted ? 1 : 0),
            .text(record.deleted ? "{}" : jsonString(record.payloadJSON)),
        ])
    }

    // MARK: - Transparent migration (DESIGN.md §6)

    public func seedProvisional(
        teamID: String,
        collection: String,
        recordID: String,
        payloadJSON: Data,
        sortKey: Double,
        now: Date
    ) throws {
        try ensureReady()
        // INSERT OR IGNORE keyed on the PK: a provisional row never overwrites an
        // existing record (provisional or authoritative). rev = 0 marks it
        // unconfirmed; a real DO record (rev >= 1) later wins by the apply guard.
        try exec("""
            INSERT OR IGNORE INTO sync_records
                (team_id, collection, record_id, rev, updated_at, sort_key, deleted, payload)
            VALUES (?, ?, ?, 0, ?, ?, 0, ?);
        """, binding: [
            .text(teamID),
            .text(collection),
            .text(recordID),
            .real(now.timeIntervalSince1970),
            .real(sortKey),
            .text(jsonString(payloadJSON)),
        ])
    }

    public func migrationCompleted(accountID: String) throws -> Bool {
        try ensureReady()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_prepare_v2(db, "SELECT value FROM sync_meta WHERE key = ?;", -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw CmuxSyncStoreError.prepareFailed(rc, lastErrorMessage())
        }
        try bind(statement: statement, parameters: [.text(migrationKey(accountID))])
        return sqlite3_step(statement) == SQLITE_ROW
    }

    public func markMigrationCompleted(accountID: String) throws {
        try ensureReady()
        try exec("INSERT OR REPLACE INTO sync_meta (key, value) VALUES (?, '1');",
                 binding: [.text(migrationKey(accountID))])
    }

    public func clear(teamID: String) throws {
        try ensureReady()
        try transaction {
            try exec("DELETE FROM sync_records WHERE team_id = ?;", binding: [.text(teamID)])
            try exec("DELETE FROM sync_cursors WHERE team_id = ?;", binding: [.text(teamID)])
        }
    }

    // MARK: - Internals

    private func migrationKey(_ accountID: String) -> String { "migrated:\(accountID)" }

    private func recordRev(teamID: String, collection: String, recordID: String) throws -> Int? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT rev FROM sync_records WHERE team_id = ? AND collection = ? AND record_id = ?;"
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else { throw CmuxSyncStoreError.prepareFailed(rc, lastErrorMessage()) }
        try bind(statement: statement, parameters: [.text(teamID), .text(collection), .text(recordID)])
        if sqlite3_step(statement) == SQLITE_ROW {
            return Int(sqlite3_column_int64(statement, 0))
        }
        return nil
    }

    private func allRecordIDs(teamID: String, collection: String, minRev: Int, maxRev: Int) throws -> [String] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            SELECT record_id FROM sync_records
            WHERE team_id = ? AND collection = ? AND rev >= ? AND rev <= ?;
        """
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else { throw CmuxSyncStoreError.prepareFailed(rc, lastErrorMessage()) }
        try bind(statement: statement, parameters: [
            .text(teamID), .text(collection), .int(Int64(minRev)), .int(Int64(maxRev)),
        ])
        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let cString = sqlite3_column_text(statement, 0) {
                ids.append(String(cString: cString))
            }
        }
        return ids
    }

    private func deleteRecord(teamID: String, collection: String, recordID: String) throws {
        try exec("DELETE FROM sync_records WHERE team_id = ? AND collection = ? AND record_id = ?;",
                 binding: [.text(teamID), .text(collection), .text(recordID)])
    }

    private func setCursor(teamID: String, collection: String, to rev: Int, now: Date) throws {
        // Monotone: never move the cursor backward. By construction frameRev is
        // always > current for an in-order stream, but MAX is the safety net.
        try exec("""
            INSERT INTO sync_cursors (team_id, collection, cursor_rev, synced_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(team_id, collection) DO UPDATE SET
                cursor_rev = MAX(cursor_rev, excluded.cursor_rev),
                synced_at = excluded.synced_at;
        """, binding: [
            .text(teamID), .text(collection), .int(Int64(rev)), .real(now.timeIntervalSince1970),
        ])
    }

    private func readRecord(_ statement: OpaquePointer?, teamID: String, collection: String) -> StoredSyncRecord {
        let recordID = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
        let rev = Int(sqlite3_column_int64(statement, 1))
        let updatedAt = sqlite3_column_double(statement, 2)
        let sortKey = sqlite3_column_double(statement, 3)
        let deleted = sqlite3_column_int(statement, 4) != 0
        let payload = sqlite3_column_text(statement, 5).map { String(cString: $0) } ?? "{}"
        return StoredSyncRecord(
            collection: collection,
            recordID: recordID,
            rev: rev,
            updatedAt: updatedAt,
            sortKey: sortKey,
            deleted: deleted,
            payloadJSON: Data(payload.utf8)
        )
    }

    private func jsonString(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? "{}"
    }

    private func userVersion() throws -> Int32 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil)
        guard rc == SQLITE_OK else { throw CmuxSyncStoreError.prepareFailed(rc, lastErrorMessage()) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else { throw CmuxSyncStoreError.stepFailed(step, lastErrorMessage()) }
        return sqlite3_column_int(statement, 0)
    }

    private func setUserVersion(_ version: Int32) throws {
        try exec("PRAGMA user_version = \(version);")
    }

    // MARK: - Statement helpers (mirror MobilePairedMacStore)

    private enum BindValue {
        case text(String)
        case int(Int64)
        case real(Double)
        case null
    }

    private func exec(_ sql: String, binding parameters: [BindValue] = []) throws {
        if parameters.isEmpty {
            let rc = sqlite3_exec(db, sql, nil, nil, nil)
            guard rc == SQLITE_OK else { throw CmuxSyncStoreError.stepFailed(rc, lastErrorMessage()) }
            return
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else { throw CmuxSyncStoreError.prepareFailed(rc, lastErrorMessage()) }
        try bind(statement: statement, parameters: parameters)
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE || step == SQLITE_ROW else {
            throw CmuxSyncStoreError.stepFailed(step, lastErrorMessage())
        }
    }

    private func bind(statement: OpaquePointer?, parameters: [BindValue]) throws {
        for (index, value) in parameters.enumerated() {
            let pos = Int32(index + 1)
            let rc: Int32
            switch value {
            case .text(let s):
                rc = s.withCString { ptr in
                    sqlite3_bind_text(statement, pos, ptr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            case .int(let i):
                rc = sqlite3_bind_int64(statement, pos, i)
            case .real(let d):
                rc = sqlite3_bind_double(statement, pos, d)
            case .null:
                rc = sqlite3_bind_null(statement, pos)
            }
            guard rc == SQLITE_OK else { throw CmuxSyncStoreError.stepFailed(rc, lastErrorMessage()) }
        }
    }

    private func transaction(_ block: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try block()
            try exec("COMMIT;")
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    private func lastErrorMessage() -> String {
        guard let cString = sqlite3_errmsg(db) else { return "" }
        return String(cString: cString)
    }
}
