import Foundation
import SQLite3

struct PendingUnregister: Codable, Hashable, Sendable {
    let tokenHex: String
    let accountID: String
}

/// Indexed durable storage for privacy-sensitive push cleanup obligations.
///
/// UserDefaults retains its domain in memory and is a poor fit for a queue that
/// can outlive several accounts. SQLite keeps the working set bounded: retries
/// read at most their requested batch, token reassignment uses an indexed
/// delete, and the uniqueness constraint compacts duplicate obligations.
final class PendingUnregisterStore {
    private var database: OpaquePointer?

    init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &opened, flags, nil) == SQLITE_OK,
              let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw PendingUnregisterStoreError.openFailed
        }
        database = opened
        do {
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA synchronous=FULL;")
            try execute("PRAGMA auto_vacuum=INCREMENTAL;")
            try execute(
                """
                CREATE TABLE IF NOT EXISTS pending_unregister (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    token_hex TEXT NOT NULL,
                    account_id TEXT NOT NULL,
                    UNIQUE(token_hex, account_id)
                );
                """
            )
            try execute(
                """
                CREATE INDEX IF NOT EXISTS pending_unregister_account_sequence
                ON pending_unregister(account_id, sequence);
                """
            )
            try execute(
                """
                CREATE INDEX IF NOT EXISTS pending_unregister_token
                ON pending_unregister(token_hex);
                """
            )
        } catch {
            sqlite3_close_v2(opened)
            database = nil
            throw error
        }
    }

    deinit {
        if let database {
            sqlite3_close_v2(database)
        }
    }

    @discardableResult
    func insert(_ entry: PendingUnregister) -> Bool {
        guard let statement = prepare(
            """
            INSERT OR IGNORE INTO pending_unregister(token_hex, account_id)
            VALUES (?, ?);
            """
        ) else { return false }
        defer { sqlite3_finalize(statement) }
        guard bind(entry.tokenHex, to: statement, at: 1),
              bind(entry.accountID, to: statement, at: 2),
              sqlite3_step(statement) == SQLITE_DONE else { return false }
        return true
    }

    /// Inserts a legacy queue in one durable transaction. This keeps launch
    /// migration linear and pays at most one FULL-synchronous commit.
    @discardableResult
    func insertAll(_ entries: [PendingUnregister]) -> Bool {
        guard !entries.isEmpty else { return true }
        guard sqlite3_exec(
            database,
            "BEGIN IMMEDIATE;",
            nil,
            nil,
            nil
        ) == SQLITE_OK else { return false }
        var committed = false
        defer {
            if !committed {
                _ = sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            }
        }
        guard let statement = prepare(
            """
            INSERT OR IGNORE INTO pending_unregister(token_hex, account_id)
            VALUES (?, ?);
            """
        ) else { return false }
        defer { sqlite3_finalize(statement) }
        for entry in entries {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            guard bind(entry.tokenHex, to: statement, at: 1),
                  bind(entry.accountID, to: statement, at: 2),
                  sqlite3_step(statement) == SQLITE_DONE else { return false }
        }
        guard sqlite3_exec(database, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            return false
        }
        committed = true
        return true
    }

    func batch(accountID: String, limit: Int) -> [PendingUnregister] {
        guard limit > 0, let statement = prepare(
            """
            SELECT token_hex, account_id
            FROM pending_unregister
            WHERE account_id = ?
            ORDER BY sequence
            LIMIT ?;
            """
        ) else { return [] }
        defer { sqlite3_finalize(statement) }
        guard bind(accountID, to: statement, at: 1),
              sqlite3_bind_int64(statement, 2, Int64(limit)) == SQLITE_OK else {
            return []
        }
        var result: [PendingUnregister] = []
        result.reserveCapacity(limit)
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let token = sqlite3_column_text(statement, 0),
                  let account = sqlite3_column_text(statement, 1) else {
                continue
            }
            result.append(PendingUnregister(
                tokenHex: String(cString: token),
                accountID: String(cString: account)
            ))
        }
        return result
    }

    @discardableResult
    func remove(tokenHex: String, accountID: String) -> Bool {
        guard let statement = prepare(
            """
            DELETE FROM pending_unregister
            WHERE token_hex = ? AND account_id = ?;
            """
        ) else { return false }
        defer { sqlite3_finalize(statement) }
        guard bind(tokenHex, to: statement, at: 1),
              bind(accountID, to: statement, at: 2),
              sqlite3_step(statement) == SQLITE_DONE else { return false }
        compactFreedPages()
        return true
    }

    @discardableResult
    func removeAll(tokenHex: String) -> Bool {
        guard let statement = prepare(
            "DELETE FROM pending_unregister WHERE token_hex = ?;"
        ) else { return false }
        defer { sqlite3_finalize(statement) }
        guard bind(tokenHex, to: statement, at: 1),
              sqlite3_step(statement) == SQLITE_DONE else { return false }
        compactFreedPages()
        return true
    }

    var hasEntries: Bool {
        guard let statement = prepare(
            "SELECT 1 FROM pending_unregister LIMIT 1;"
        ) else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func compactFreedPages() {
        _ = sqlite3_exec(database, "PRAGMA incremental_vacuum(4);", nil, nil, nil)
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw PendingUnregisterStoreError.schemaFailed
        }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        return statement
    }

    private func bind(
        _ value: String,
        to statement: OpaquePointer,
        at index: Int32
    ) -> Bool {
        value.withCString { pointer in
            sqlite3_bind_text(
                statement,
                index,
                pointer,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            ) == SQLITE_OK
        }
    }
}

private enum PendingUnregisterStoreError: Error {
    case openFailed
    case schemaFailed
}
