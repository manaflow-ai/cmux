public import Foundation
import SQLite3
import os

private let syncStoreLog = Logger(subsystem: "com.cmuxterm.app", category: "CmuxSyncStore")

/// Local-first sync store: one raw-SQLite3 database backing the generic sync
/// substrate (DESIGN.md §4). This is a deliberate clone of
/// ``MobilePairedMacStore``'s pattern — an `actor` serializing a
/// `SQLITE_OPEN_FULLMUTEX` connection (owned by ``SyncDatabase``, which keeps the
/// raw handle private and provides the binder), with `PRAGMA user_version` lazy
/// migrations — extended to one generic `sync_records` table keyed by
/// `(team_id, collection, record_id)` plus a `sync_cursors` table. Typed facades
/// (e.g. ``DeviceSyncFacade``) read/write through it; the store stays generic.
public actor CmuxSyncStore: CmuxSyncStoring {
    public static let currentSchemaVersion: Int32 = 1

    private let dbPath: String
    // The raw `sqlite3` handle lives PRIVATELY inside `SyncDatabase` (see
    // SyncDatabase.swift), so it is never module-visible and the actor-isolation
    // invariant on the connection cannot be broken by other module files. This
    // actor owns the only reference; `nonisolated` so the nonisolated `deinit` can
    // close it (the type is Sendable, so no `unsafe` is needed).
    nonisolated private let db: SyncDatabase

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
        self.db = try SyncDatabase(path: databaseURL.path)
    }

    public init() throws {
        try self.init(databaseURL: Self.defaultDatabaseURL())
    }

    deinit {
        db.close()
    }

    // MARK: - Open + migrate

    private var didMigrate = false

    private func ensureReady() throws {
        guard !didMigrate else { return }
        try runMigrations()
        didMigrate = true
    }

    private func runMigrations() throws {
        let version = try db.userVersion()
        switch version {
        case 0:
            try migrateToV1()
            try db.setUserVersion(1)
            fallthrough
        case 1:
            break
        default:
            throw CmuxSyncStoreError.unknownSchemaVersion(Int(version))
        }
    }

    private func migrateToV1() throws {
        // One row per synced record across all collections; payload opaque JSON.
        try db.exec("""
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
        try db.exec("""
            CREATE INDEX IF NOT EXISTS idx_sync_records_render
              ON sync_records (team_id, collection, deleted, sort_key);
        """)
        // One row per (team, collection): the durable cursor watermark plus the
        // history generation (epoch) the cursor belongs to.
        try db.exec("""
            CREATE TABLE IF NOT EXISTS sync_cursors (
                team_id     TEXT    NOT NULL,
                collection  TEXT    NOT NULL,
                cursor_rev  INTEGER NOT NULL DEFAULT 0,
                epoch       INTEGER NOT NULL DEFAULT 0,
                synced_at   REAL    NOT NULL DEFAULT 0,
                PRIMARY KEY (team_id, collection)
            );
        """)
        // Idempotency markers for the one-time transparent migration per account.
        try db.exec("""
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
        statement = try db.prepare(sql)
        try db.bind(statement: statement, parameters: [.text(teamID), .text(collection)])
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
        statement = try db.prepare(sql)
        try db.bind(statement: statement, parameters: [.text(teamID), .text(collection)])
        if sqlite3_step(statement) == SQLITE_ROW {
            return Int(sqlite3_column_int64(statement, 0))
        }
        return 0
    }

    public func epoch(teamID: String, collection: String) throws -> Int {
        try ensureReady()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT epoch FROM sync_cursors WHERE team_id = ? AND collection = ?;"
        statement = try db.prepare(sql)
        try db.bind(statement: statement, parameters: [.text(teamID), .text(collection)])
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
        try db.transaction {
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
        epoch: Int,
        records: [SyncWireRecord],
        sortKeyFor: @Sendable (SyncWireRecord) -> Double,
        now: Date
    ) throws {
        try ensureReady()
        try db.transaction {
            // Reset detection. The DO history was reset/rolled back when either:
            //   (a) our local cursor is AHEAD of this snapshot's rev (the worker
            //       forced this snapshot because cursor > head), OR
            //   (b) the snapshot's epoch differs from the epoch we last synced
            //       against — this catches an equal-head reset (a new history
            //       coincidentally at the same head as our cached old history),
            //       which the cursor check alone cannot see (DESIGN.md §3.6).
            // In a reset the snapshot is the new ground truth: replace its records
            // unconditionally, reconcile ALL authoritative rows (any rev) absent
            // from it, and force the cursor + epoch to the snapshot's values.
            let localCursor = try cursor(teamID: teamID, collection: collection)
            let localEpoch = try self.epoch(teamID: teamID, collection: collection)
            // A nonzero incoming epoch that differs from ours is a reset — INCLUDING
            // when our local epoch is 0 (a pre-epoch cache, or a first sync that
            // already has rows from an old history). The worker force-snapshots a
            // clientEpoch-0 client against a real server, so we must apply it
            // authoritatively; otherwise a same-id/same-rev record with a changed
            // payload would be skipped by the monotone guard and stay stale
            // (DESIGN.md §3.6). A pure first sync (no local rows) is harmless here:
            // there is nothing to force-replace or reconcile away.
            let epochChanged = epoch != 0 && epoch != localEpoch
            let isReset = localCursor > snapshotRev || epochChanged

            var present = Set<String>()
            for record in records {
                if isReset {
                    try forceApplyRecord(teamID: teamID, collection: collection, record: record, sortKey: sortKeyFor(record))
                } else {
                    try applyOneRecord(teamID: teamID, collection: collection, record: record, sortKey: sortKeyFor(record))
                }
                present.insert(record.id)
            }
            // Missing-record reconciliation. Normally scoped to authoritative rows
            // in [1, snapshotRev] (a record deleted while disconnected). On a reset
            // it covers ALL authoritative rows (up to Int.max), since old-history
            // revs can exceed snapshotRev. Provisional rev == 0 migration rows are
            // EXEMPT either way and survive (DESIGN.md §3.2a/§6).
            //
            // We TOMBSTONE rather than hard-delete: a hard delete drops the rev
            // watermark, letting a queued/duplicate delta resurrect the row, since
            // applyOneRecord reads nil for a missing record. The tombstone at
            // snapshotRev is excluded from the live read and its rev makes the
            // guard ignore any later rev <= snapshotRev delta for that id.
            let maxRev = isReset ? Int.max : snapshotRev
            let existing = try allRecordIDs(teamID: teamID, collection: collection, minRev: 1, maxRev: maxRev)
            for id in existing where !present.contains(id) {
                // Tombstone rev: normally snapshotRev. On a reset, a stale row can
                // have a rev FAR ABOVE snapshotRev (from the old high-rev history);
                // tombstoning at snapshotRev would let a queued old-history delta
                // (rev > snapshotRev) pass the monotone guard and resurrect it. So
                // tombstone at max(snapshotRev, localRev) to dominate any
                // old-history delta for that id.
                let localRev = try recordRev(teamID: teamID, collection: collection, recordID: id) ?? 0
                let tombRev = isReset ? max(snapshotRev, localRev) : snapshotRev
                try tombstoneAt(teamID: teamID, collection: collection, recordID: id, rev: tombRev, now: now)
            }
            // On a reset the cursor must move DOWN to the new head; setCursor's MAX
            // would keep the stale ahead cursor, so force it on reset. The
            // snapshot's epoch is recorded either way (it is the generation this
            // committed state belongs to; a first sync adopts the server epoch).
            if isReset {
                try forceCursor(teamID: teamID, collection: collection, to: snapshotRev, epoch: epoch, now: now)
            } else {
                try setCursor(teamID: teamID, collection: collection, to: snapshotRev, epoch: epoch, now: now)
            }
        }
    }

    /// Apply one record UNCONDITIONALLY (no monotone guard), used during a reset
    /// snapshot where the snapshot is the new ground truth and local revs come
    /// from an obsolete history.
    private func forceApplyRecord(teamID: String, collection: String, record: SyncWireRecord, sortKey: Double) throws {
        let updatedAtSeconds = record.updatedAt / 1000.0
        try db.exec("""
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
        try db.exec("""
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
        try db.exec("""
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

    public func migrationCompleted(accountID: String, teamID: String) throws -> Bool {
        try ensureReady()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        statement = try db.prepare("SELECT value FROM sync_meta WHERE key = ?;")
        try db.bind(statement: statement, parameters: [.text(migrationKey(accountID: accountID, teamID: teamID))])
        return sqlite3_step(statement) == SQLITE_ROW
    }

    public func markMigrationCompleted(accountID: String, teamID: String) throws {
        try ensureReady()
        try db.exec("INSERT OR REPLACE INTO sync_meta (key, value) VALUES (?, '1');",
                 binding: [.text(migrationKey(accountID: accountID, teamID: teamID))])
    }

    public func clear(teamID: String) throws {
        try ensureReady()
        try db.transaction {
            try db.exec("DELETE FROM sync_records WHERE team_id = ?;", binding: [.text(teamID)])
            try db.exec("DELETE FROM sync_cursors WHERE team_id = ?;", binding: [.text(teamID)])
            // Clear this team's migration markers too, so a re-sign-in re-seeds
            // the provisional fallback rows we just deleted. The stored key holds
            // the RAW team id; escape it only for the LIKE pattern (so a team id
            // containing `_`, `%`, or `\` still matches its own stored key).
            try db.exec("DELETE FROM sync_meta WHERE key LIKE ? ESCAPE '\\';",
                     binding: [.text("\(escapeLike(migrationKeyPrefix(teamID: teamID)))%")])
        }
    }

    // MARK: - Internals

    /// Migration marker key, scoped by team THEN account so a team's markers form
    /// a `migrated:<teamId>:` prefix `clear(teamID)` can delete. The team id is
    /// stored RAW (unescaped); `clear` escapes it only when building its LIKE
    /// pattern, so a team id with `_`/`%`/`\` still matches its own stored key.
    private func migrationKey(accountID: String, teamID: String) -> String {
        "\(migrationKeyPrefix(teamID: teamID))\(accountID)"
    }

    private func migrationKeyPrefix(teamID: String) -> String {
        "migrated:\(teamID):"
    }

    /// Escape `%`, `_`, and the `\` escape char so a literal string matches
    /// itself under `LIKE ... ESCAPE '\'`. Applied to the LIKE PATTERN only,
    /// never to the stored key.
    private func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func recordRev(teamID: String, collection: String, recordID: String) throws -> Int? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT rev FROM sync_records WHERE team_id = ? AND collection = ? AND record_id = ?;"
        statement = try db.prepare(sql)
        try db.bind(statement: statement, parameters: [.text(teamID), .text(collection), .text(recordID)])
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
        statement = try db.prepare(sql)
        try db.bind(statement: statement, parameters: [
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

    /// Write a tombstone for a record at a given rev (the snapshot-reconciliation
    /// deletion watermark). Excluded from the live read; its rev guards against a
    /// later stale delta resurrecting the record. Idempotent via the PK upsert.
    private func tombstoneAt(teamID: String, collection: String, recordID: String, rev: Int, now: Date) throws {
        try db.exec("""
            INSERT INTO sync_records (team_id, collection, record_id, rev, updated_at, sort_key, deleted, payload)
            VALUES (?, ?, ?, ?, ?, 0, 1, '{}')
            ON CONFLICT(team_id, collection, record_id) DO UPDATE SET
                rev = excluded.rev,
                updated_at = excluded.updated_at,
                deleted = 1,
                payload = '{}';
        """, binding: [
            .text(teamID),
            .text(collection),
            .text(recordID),
            .int(Int64(rev)),
            .real(now.timeIntervalSince1970),
        ])
    }

    /// Advance the cursor monotonically (never backward). `epoch` nil = preserve
    /// the existing epoch (the delta path); a value adopts the server epoch (a
    /// snapshot commit). On first insert, a nil epoch defaults to 0.
    private func setCursor(teamID: String, collection: String, to rev: Int, epoch: Int? = nil, now: Date) throws {
        try db.exec("""
            INSERT INTO sync_cursors (team_id, collection, cursor_rev, epoch, synced_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(team_id, collection) DO UPDATE SET
                cursor_rev = MAX(cursor_rev, excluded.cursor_rev),
                epoch = CASE WHEN ? THEN excluded.epoch ELSE sync_cursors.epoch END,
                synced_at = excluded.synced_at;
        """, binding: [
            .text(teamID), .text(collection), .int(Int64(rev)), .int(Int64(epoch ?? 0)),
            .real(now.timeIntervalSince1970), .int(epoch != nil ? 1 : 0),
        ])
    }

    /// Set the cursor UNCONDITIONALLY (no MAX) and adopt the given epoch, used on
    /// a reset snapshot to move the cursor DOWN to the new (lower) head and into
    /// the new history generation so the client converges to the reset DO history.
    private func forceCursor(teamID: String, collection: String, to rev: Int, epoch: Int, now: Date) throws {
        try db.exec("""
            INSERT INTO sync_cursors (team_id, collection, cursor_rev, epoch, synced_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(team_id, collection) DO UPDATE SET
                cursor_rev = excluded.cursor_rev,
                epoch = excluded.epoch,
                synced_at = excluded.synced_at;
        """, binding: [
            .text(teamID), .text(collection), .int(Int64(rev)), .int(Int64(epoch)),
            .real(now.timeIntervalSince1970),
        ])
    }

}
