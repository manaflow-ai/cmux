public import Foundation
import SQLite3
import CmuxNextCompat

/// A read-only SQLite database opened from a private copy of the file (and
/// its `-wal`), so a browser that is running and holds the database locked
/// does not block or fail the read, and the source is never written.
///
/// Memory safety, as Chromium's sql::Database and sql::Statement
/// (sql/database.cc, sql/statement.cc): `handle` is the connection `init`
/// opened and `deinit` closes once, so it is live in every method. Each
/// statement is prepared, stepped and finalized inside one `query` call, and
/// its rows reach the caller only as a borrowed ``SQLiteRow``, which is
/// `~Copyable` and so cannot outlive the step that produced it.
@safe
public final class SQLiteSnapshot {
    public enum Failure: Error, Equatable {
        case copy(String)
        case open(String)
        case query(String)
    }

    private let handle: OpaquePointer
    private let directory: URL

    public init(copying source: URL) throws {
        let manager = FileManager.default
        directory = manager.temporaryDirectory.appending(path: "cmux-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        let copy = directory.appending(path: "db.sqlite")
        do {
            try FileManager.checked.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.checked.copyItem(at: source, to: copy)
            for suffix in ["-wal", "-journal"] {
                let side = URL(fileURLWithPath: source.path + suffix)
                if FileManager.checked.fileExists(atPath: side.path) { try? FileManager.checked.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix)) }
            }
        } catch {
            try? FileManager.checked.removeItem(at: directory)
            throw Failure.copy(error.localizedDescription)
        }
        var opened: OpaquePointer?
        // Read-write on the private copy so SQLite can replay the WAL.
        // SAFETY: the path is a NUL-terminated copy Swift keeps alive for the call; SQLite writes one
        // connection (or NULL) into the local `opened` and keeps no pointer to either.
        let status = unsafe blockingSQLiteOpen(copy.path, &opened, SQLITE_OPEN_READWRITE, nil)
        guard status == SQLITE_OK, let connection = unsafe opened else {
            var message = "open failed"
            if let failed = unsafe opened {
                // SAFETY: a failed open may still return a connection holding the error; errmsg's
                // NUL-terminated text belongs to it, and String copies it before close frees it below.
                message = unsafe String(cString: sqlite3_errmsg(failed))
            }
            // SAFETY: closes the connection open returned (or NULL, which does nothing) once; nothing
            // uses it after.
            unsafe blockingSQLiteClose(opened)
            try? FileManager.checked.removeItem(at: directory)
            throw Failure.open(message)
        }
        // SAFETY: stores the owned connection; deinit closes it.
        unsafe handle = connection
    }

    deinit {
        // SAFETY: closes the connection init opened, exactly once; every statement on it was finalized
        // by the query that prepared it.
        unsafe blockingSQLiteClose(handle)
        try? FileManager.default.removeItem(at: directory)
    }

    /// SQLite's message for the connection's last error.
    private var lastError: String {
        // SAFETY: handle is live (see the type); errmsg's NUL-terminated text belongs to the
        // connection until its next call, and String copies it now.
        unsafe String(cString: sqlite3_errmsg(handle))
    }

    /// Runs `sql` and calls `row` for each result row. `row` returns false to stop.
    /// Checks for task cancellation every 256 rows.
    public func query(_ sql: String, _ row: (borrowing SQLiteRow) throws -> Bool) throws {
        var prepared: OpaquePointer?
        // SAFETY: handle is live (see the type); `sql` is a NUL-terminated copy Swift keeps alive for the
        // call (length -1 reads to the NUL), and SQLite writes one statement (or NULL) into `prepared`.
        guard unsafe blockingSQLitePrepare(handle, sql, -1, &prepared, nil) == SQLITE_OK else {
            throw Failure.query(lastError)
        }
        // SQL with no statement in it (only a comment) prepares NULL; stepping it would be a misuse.
        guard let statement = unsafe prepared else { throw Failure.query(lastError) }
        // SAFETY: finalizes the statement prepared above once, after its last step; no row outlives the
        // closure call it was lent to.
        defer { unsafe sqlite3_finalize(statement) }
        // SAFETY: reads the column count of the live statement prepared above.
        let columns = unsafe sqlite3_column_count(statement)
        var count = 0
        while true { // wakeup-allow: bounded by the result set; ends at SQLITE_DONE
            // SAFETY: steps the live statement prepared above on the live connection.
            let step = unsafe blockingSQLiteStep(statement)
            if step == SQLITE_DONE { return }
            guard step == SQLITE_ROW else { throw Failure.query(lastError) }
            count += 1
            if count % 256 == 0 { try Task.checkCancellation() }
            // SAFETY: the statement is live and on a row until the next step or the finalize above, both
            // after `row` returns; the row is lent to `row` only, and is ~Copyable, so it cannot be kept.
            let current = unsafe SQLiteRow(statement: statement, columns: columns)
            guard try row(current) else { return }
        }
    }

    /// The pages a history query leaves out in SQL, before its `ORDER BY … LIMIT`: the address is not
    /// importable (``ImportableURL/sqlFilter(_:)``), or else the time is not `kept`. `source` is the
    /// query's `FROM … WHERE` naming every page it would read.
    func skippedPages(url: String, kept: String, source: String) throws -> ImportSkipCounts {
        let importable = ImportableURL.sqlFilter(url)
        var skipped = ImportSkipCounts()
        let sql = """
            SELECT SUM(CASE WHEN \(importable) THEN 0 ELSE 1 END),
                   SUM(CASE WHEN \(importable) THEN (CASE WHEN \(kept) THEN 0 ELSE 1 END) ELSE 0 END) \(source)
            """
        try query(sql) { row in
            skipped.notImportable = row.int(0)
            skipped.badTime = row.int(1)
            return false
        }
        return skipped
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

/// One result row; column access by index. A column past the result's
/// columns reads as NULL (0, nil), as SQLite's own NULL would.
///
/// Memory safety: `statement` is the statement ``SQLiteSnapshot/query(_:_:)``
/// stepped to this row; it stays on the row until the closure that borrows
/// this value returns, and the type is `~Copyable`, so no copy outlives that.
/// Every read checks the column against `columns` first (Chromium's
/// sql::Statement checks its column index the same way), and text and blobs
/// are copied before the read returns.
@safe
public struct SQLiteRow: ~Copyable {
    private let statement: OpaquePointer
    private let columns: Int32

    init(statement: OpaquePointer, columns: Int32) {
        // SAFETY: stores the statement query lent this row for (see the type).
        unsafe self.statement = statement
        self.columns = columns
    }

    private func has(_ column: Int32) -> Bool { column >= 0 && column < columns }

    public func int64(_ column: Int32) -> Int64 {
        guard has(column) else { return 0 }
        // SAFETY: the statement is on this row (see the type) and the column is in range.
        return unsafe sqlite3_column_int64(statement, column)
    }

    /// The integer as an `Int`: exact, every Mac's `Int` has SQLite's 64 bits.
    public func int(_ column: Int32) -> Int {
        Int(truncatingIfNeeded: int64(column))
    }

    public func double(_ column: Int32) -> Double {
        guard has(column) else { return 0 }
        // SAFETY: the statement is on this row (see the type) and the column is in range.
        return unsafe sqlite3_column_double(statement, column)
    }

    public func isNull(_ column: Int32) -> Bool {
        guard has(column) else { return true }
        // SAFETY: the statement is on this row (see the type) and the column is in range.
        return unsafe sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    public func string(_ column: Int32) -> String? {
        guard has(column) else { return nil }
        // SAFETY: the statement is on this row (see the type) and the column is in range. The text is
        // NUL-terminated and belongs to the statement until its next call; String copies it now.
        guard let text = unsafe sqlite3_column_text(statement, column) else { return nil }
        return unsafe String(cString: text)
    }

    public func data(_ column: Int32) -> Data? {
        guard has(column) else { return nil }
        // SAFETY: the statement is on this row (see the type) and the column is in range. The blob is
        // asked for before its size, SQLite's documented order, so `bytes` holds the size reported;
        // Data copies them before the next call on the statement.
        guard let bytes = unsafe sqlite3_column_blob(statement, column) else { return nil }
        return unsafe Data(bytes: bytes, count: sqlite3_column_bytes(statement, column).widened)
    }
}
