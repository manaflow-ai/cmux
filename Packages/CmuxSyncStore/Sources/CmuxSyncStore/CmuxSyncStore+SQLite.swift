import Foundation
import SQLite3

/// Low-level SQLite3 statement helpers for ``CmuxSyncStore`` (the `PRAGMA
/// user_version` accessors and the `BindValue` binder), split out of the main
/// store so the public store API file stays focused. Mirrors the same helper
/// shape as `MobilePairedMacStore`. These are actor-isolated extension methods
/// (same module), so they read the actor's `db` handle directly.
extension CmuxSyncStore {
    enum BindValue {
        case text(String)
        case int(Int64)
        case real(Double)
        case null
    }

    func userVersion() throws -> Int32 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil)
        guard rc == SQLITE_OK else { throw CmuxSyncStoreError.prepareFailed(rc, lastErrorMessage()) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else { throw CmuxSyncStoreError.stepFailed(step, lastErrorMessage()) }
        return sqlite3_column_int(statement, 0)
    }

    func setUserVersion(_ version: Int32) throws {
        try exec("PRAGMA user_version = \(version);")
    }

    func exec(_ sql: String, binding parameters: [BindValue] = []) throws {
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

    func bind(statement: OpaquePointer?, parameters: [BindValue]) throws {
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

    func transaction(_ block: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try block()
            try exec("COMMIT;")
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    func lastErrorMessage() -> String {
        guard let cString = sqlite3_errmsg(db) else { return "" }
        return String(cString: cString)
    }

    /// Write a tombstone for a record at a given rev (the snapshot-reconciliation
    /// deletion watermark). Excluded from the live read; its rev guards against a
    /// later stale delta resurrecting the record. Idempotent via the PK upsert.
    func tombstoneAt(teamID: String, collection: String, recordID: String, rev: Int, now: Date) throws {
        try exec("""
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
    func setCursor(teamID: String, collection: String, to rev: Int, epoch: Int? = nil, now: Date) throws {
        try exec("""
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
    func forceCursor(teamID: String, collection: String, to rev: Int, epoch: Int, now: Date) throws {
        try exec("""
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
