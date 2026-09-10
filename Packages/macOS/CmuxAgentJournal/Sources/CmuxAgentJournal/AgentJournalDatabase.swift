internal import Foundation
internal import SQLite3

/// Thin owner of one raw `sqlite3` connection plus prepared-statement helpers
/// (mirrors `CmuxSyncStore`'s `SyncDatabase` binder).
///
/// The raw `OpaquePointer` handle is private to this file, so the store's
/// serialization invariant cannot be violated by a stray helper.
/// `AgentJournalStore` guards every call with its own lock and additionally
/// opens the connection `SQLITE_OPEN_FULLMUTEX`; this type is therefore
/// `@unchecked Sendable`: it is only ever touched under the owning store's
/// lock (and the owner's `close()` tears it down), never shared concurrently.
final class AgentJournalDatabase: @unchecked Sendable {
    enum BindValue {
        case text(String)
        case int(Int64)
        case null

        static func optionalText(_ value: String?) -> BindValue {
            value.map { .text($0) } ?? .null
        }
    }

    private let handle: OpaquePointer

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw AgentJournalStoreError.openFailed(rc)
        }
        // WAL for concurrent-reader friendliness; FULL synchronous so the
        // append acknowledgement returned to the hook emitter is durable.
        for pragma in [
            "PRAGMA busy_timeout = 5000;",
            "PRAGMA foreign_keys = ON;",
            "PRAGMA journal_mode = WAL;",
            "PRAGMA synchronous = FULL;",
        ] {
            let prc = sqlite3_exec(handle, pragma, nil, nil, nil)
            guard prc == SQLITE_OK else {
                let message = sqlite3_errmsg(handle).map { String(cString: $0) } ?? ""
                sqlite3_close_v2(handle)
                throw AgentJournalStoreError.stepFailed(prc, "\(pragma) failed: \(message)")
            }
        }
        self.handle = handle
    }

    func close() {
        sqlite3_close_v2(handle)
    }

    /// Prepare a statement, throwing `.prepareFailed` on error. The caller
    /// owns finalizing it (`defer { sqlite3_finalize(stmt) }`).
    func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw AgentJournalStoreError.prepareFailed(rc, lastErrorMessage())
        }
        return statement
    }

    func exec(_ sql: String, binding parameters: [BindValue] = []) throws {
        if parameters.isEmpty {
            let rc = sqlite3_exec(handle, sql, nil, nil, nil)
            guard rc == SQLITE_OK else {
                throw AgentJournalStoreError.stepFailed(rc, lastErrorMessage())
            }
            return
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        statement = try prepare(sql)
        try bind(statement: statement, parameters: parameters)
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE || step == SQLITE_ROW else {
            throw AgentJournalStoreError.stepFailed(step, lastErrorMessage())
        }
    }

    func bind(statement: OpaquePointer?, parameters: [BindValue]) throws {
        for (index, value) in parameters.enumerated() {
            let position = Int32(index + 1)
            let rc: Int32
            switch value {
            case .text(let string):
                rc = string.withCString { pointer in
                    sqlite3_bind_text(
                        statement,
                        position,
                        pointer,
                        -1,
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    )
                }
            case .int(let integer):
                rc = sqlite3_bind_int64(statement, position, integer)
            case .null:
                rc = sqlite3_bind_null(statement, position)
            }
            guard rc == SQLITE_OK else {
                throw AgentJournalStoreError.stepFailed(rc, lastErrorMessage())
            }
        }
    }

    func transaction<Result>(_ block: () throws -> Result) throws -> Result {
        try exec("BEGIN IMMEDIATE;")
        do {
            let result = try block()
            try exec("COMMIT;")
            return result
        } catch {
            _ = sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    func columnInt64(_ statement: OpaquePointer?, _ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func step(_ statement: OpaquePointer?) -> Int32 {
        sqlite3_step(statement)
    }

    func lastErrorMessage() -> String {
        guard let cString = sqlite3_errmsg(handle) else { return "" }
        return String(cString: cString)
    }
}
