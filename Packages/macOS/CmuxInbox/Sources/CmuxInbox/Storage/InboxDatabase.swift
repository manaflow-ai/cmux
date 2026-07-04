import Foundation
import SQLite3

// Wraps a raw sqlite3 handle. The owning `InboxSQLiteStore` actor serializes all access.
final class InboxDatabase: @unchecked Sendable {
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
            throw InboxError.openFailed(rc)
        }
        self.handle = handle
        try exec("PRAGMA foreign_keys = ON;")
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous = NORMAL;")
    }

    func close() {
        sqlite3_close_v2(handle)
    }

    func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw InboxError.prepareFailed(rc, lastErrorMessage())
        }
        return statement
    }

    func userVersion() throws -> Int32 {
        let statement = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else { throw InboxError.stepFailed(step, lastErrorMessage()) }
        return sqlite3_column_int(statement, 0)
    }

    func setUserVersion(_ version: Int32) throws {
        try exec("PRAGMA user_version = \(version);")
    }

    func exec(_ sql: String, binding parameters: [BindValue] = []) throws {
        if parameters.isEmpty {
            let rc = sqlite3_exec(handle, sql, nil, nil, nil)
            guard rc == SQLITE_OK else { throw InboxError.stepFailed(rc, lastErrorMessage()) }
            return
        }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement: statement, parameters: parameters)
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE || step == SQLITE_ROW else {
            throw InboxError.stepFailed(step, lastErrorMessage())
        }
    }

    func bind(statement: OpaquePointer?, parameters: [BindValue]) throws {
        for (index, value) in parameters.enumerated() {
            let pos = Int32(index + 1)
            let rc: Int32
            switch value {
            case .text(let string):
                rc = string.withCString { pointer in
                    sqlite3_bind_text(statement, pos, pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            case .int(let int):
                rc = sqlite3_bind_int64(statement, pos, int)
            case .real(let double):
                rc = sqlite3_bind_double(statement, pos, double)
            case .null:
                rc = sqlite3_bind_null(statement, pos)
            }
            guard rc == SQLITE_OK else { throw InboxError.stepFailed(rc, lastErrorMessage()) }
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
