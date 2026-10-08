import Foundation
import SQLite3

/// A small read-write SQLite handle for history stores. Not thread safe:
/// one actor owns each instance.
nonisolated final class HistorySQLite {
    enum Failure: Error, Equatable {
        case open(String)
        case statement(String)
    }

    enum Value {
        case text(String)
        case integer(Int64)
        case null
    }

    private var handle: OpaquePointer?

    /// Opens (creating) the database at `url`; nil opens an in-memory one.
    init(url: URL?) throws {
        let path: String
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            path = url.path
        } else {
            path = ":memory:"
        }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            handle = nil
            throw Failure.open(message)
        }
        sqlite3_busy_timeout(handle, 250)
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw Failure.statement(String(cString: sqlite3_errmsg(handle)))
        }
    }

    /// Runs one statement with `bindings`; `row` sees each result row.
    func run(_ sql: String, _ bindings: [Value] = [], row: ((Row) -> Void)? = nil) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure.statement(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, transient)
            case .integer(let number): sqlite3_bind_int64(statement, index, number)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        while true { // wakeup-allow: bounded by the result set; ends at SQLITE_DONE
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return }
            guard step == SQLITE_ROW else { throw Failure.statement(String(cString: sqlite3_errmsg(handle))) }
            row?(Row(statement: statement))
        }
    }

    var changes: Int { Int(sqlite3_changes(handle)) }

    struct Row {
        let statement: OpaquePointer?

        func text(_ column: Int32) -> String? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL,
                  let bytes = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: bytes)
        }

        func integer(_ column: Int32) -> Int64 {
            sqlite3_column_int64(statement, column)
        }
    }
}
