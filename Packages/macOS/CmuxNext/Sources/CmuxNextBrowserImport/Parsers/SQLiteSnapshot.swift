public import Foundation
import SQLite3

/// A read-only SQLite database opened from a private copy of the file (and
/// its `-wal`), so a browser that is running and holds the database locked
/// does not block or fail the read, and the source is never written.
public final class SQLiteSnapshot {
    public enum Failure: Error, Equatable {
        case copy(String)
        case open(String)
        case query(String)
    }

    private var handle: OpaquePointer?
    private let directory: URL

    public init(copying source: URL) throws {
        let manager = FileManager.default
        directory = manager.temporaryDirectory.appending(path: "cmux-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        let copy = directory.appending(path: "db.sqlite")
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try manager.copyItem(at: source, to: copy)
            for suffix in ["-wal", "-journal"] {
                let side = URL(fileURLWithPath: source.path + suffix)
                if manager.fileExists(atPath: side.path) { try? manager.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix)) }
            }
        } catch {
            try? manager.removeItem(at: directory)
            throw Failure.copy(error.localizedDescription)
        }
        // Read-write on the private copy so SQLite can replay the WAL.
        guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            handle = nil
            try? manager.removeItem(at: directory)
            throw Failure.open(message)
        }
    }

    deinit {
        sqlite3_close(handle)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Runs `sql` and calls `row` for each result row. `row` returns false to stop.
    /// Checks for task cancellation every 256 rows.
    public func query(_ sql: String, _ row: (SQLiteRow) throws -> Bool) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure.query(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        var count = 0
        while true { // wakeup-allow: bounded by the result set; ends at SQLITE_DONE
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return }
            guard step == SQLITE_ROW else { throw Failure.query(String(cString: sqlite3_errmsg(handle))) }
            count += 1
            if count % 256 == 0 { try Task.checkCancellation() }
            guard try row(SQLiteRow(statement: statement)) else { return }
        }
    }

    /// Whether `table` exists.
    public func hasTable(_ table: String) -> Bool {
        var found = false
        try? query("SELECT 1 FROM sqlite_master WHERE type='table' AND name='\(table.replacingOccurrences(of: "'", with: "''"))'") { _ in
            found = true
            return false
        }
        return found
    }
}

/// One result row; column access by index.
public struct SQLiteRow {
    let statement: OpaquePointer?

    public func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    public func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    public func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }

    public func string(_ column: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: text)
    }

    public func data(_ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}
