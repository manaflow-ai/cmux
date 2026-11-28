import Foundation
import SQLite3

/// A thin owner of one raw `sqlite3` connection plus the prepared-statement
/// helpers (mirrors `MobilePairedMacStore`'s binder). Splitting the SQLite
/// plumbing into its own type keeps the raw `OpaquePointer` handle **private to
/// this file** — it is never module-visible, so the actor-isolation invariant on
/// the connection cannot be violated by a stray helper or future module file.
///
/// `CmuxSyncStore` holds exactly one `SyncDatabase` as a `private let` and is an
/// actor, so every call here is already serialized by the store's isolation; the
/// connection is also opened `SQLITE_OPEN_FULLMUTEX`. This type is therefore
/// `@unchecked Sendable`: it is only ever touched from inside the owning actor
/// (and the owner's nonisolated `deinit` closes it), never shared concurrently.
final class SyncDatabase: @unchecked Sendable {
    enum BindValue {
        case text(String)
        case int(Int64)
        case real(Double)
        case null
    }

    private let handle: OpaquePointer

    init(path: String) throws {
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
        self.handle = handle
    }

    func close() {
        sqlite3_close_v2(handle)
    }

    /// Prepare a statement, throwing `.prepareFailed` on error. The caller owns
    /// finalizing it (`defer { sqlite3_finalize(stmt) }`).
    func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else { throw CmuxSyncStoreError.prepareFailed(rc, lastErrorMessage()) }
        return statement
    }

    func userVersion() throws -> Int32 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        statement = try prepare("PRAGMA user_version;")
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else { throw CmuxSyncStoreError.stepFailed(step, lastErrorMessage()) }
        return sqlite3_column_int(statement, 0)
    }

    func setUserVersion(_ version: Int32) throws {
        try exec("PRAGMA user_version = \(version);")
    }

    func exec(_ sql: String, binding parameters: [BindValue] = []) throws {
        if parameters.isEmpty {
            let rc = sqlite3_exec(handle, sql, nil, nil, nil)
            guard rc == SQLITE_OK else { throw CmuxSyncStoreError.stepFailed(rc, lastErrorMessage()) }
            return
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        statement = try prepare(sql)
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
            _ = sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    func lastErrorMessage() -> String {
        guard let cString = sqlite3_errmsg(handle) else { return "" }
        return String(cString: cString)
    }
}
