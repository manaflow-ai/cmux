import CmuxNextCompat
import Foundation
import SQLite3
import os

/// A small read-write SQLite handle for history stores. Not thread safe:
/// one actor owns each instance.
nonisolated final class HistorySQLite {
    enum Failure: Error, Equatable {
        case open(String)
        /// SQLite reported the file corrupt or not a database.
        case unreadable(String)
        case statement(String)
    }

    enum Value {
        case text(String)
        case integer(Int64)
        case null
    }

    /// A file SQLite could not read (`SQLITE_CORRUPT`, `SQLITE_NOTADB`), moved aside before a new
    /// database was created at its path.
    struct SetAside: Equatable, Sendable {
        let database: URL
        /// `<name>.corrupt`, or `<name>.corrupt-<uuid>` when that exists.
        let aside: URL
        let reason: String
    }

    /// How long a statement waits for another connection's lock.
    static let busyTimeoutMilliseconds: Int32 = 250

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "history")

    /// The default fault report: one `.fault` in the unified log, which the error journal harvests.
    static func logFault(_ event: SetAside) {
        let name = event.database.lastPathComponent, aside = event.aside.lastPathComponent
        logger.fault("history database \(name, privacy: .public) was unreadable (\(event.reason, privacy: .public)); moved it to \(aside, privacy: .public) and started a new one")
    }

    private var handle: OpaquePointer?

    /// Opens (creating) the database at `url`; nil opens an in-memory one.
    ///
    /// The SQLite error policy, after Chromium's `sql::Database` error callback and `sql::Recovery`
    /// (sql/database.cc, sql/recovery.cc): a busy timeout on the handle; a file SQLite reports
    /// corrupt or not a database is moved aside with its sidecars, a new database is created in its
    /// place and `onSetAside` hears it once, as soon as the file has moved (also when the new
    /// database then fails to open). The open runs at most twice, so a start never loops.
    /// `opener` is the open seam; a test makes its second run fail.
    init(
        url: URL?,
        onSetAside: (SetAside) -> Void = HistorySQLite.logFault,
        opener: (String) -> Result<OpaquePointer, Failure> = HistorySQLite.openHandle(path:)
    ) throws {
        guard let url else {
            handle = try opener(":memory:").get()
            return
        }
        try FileManager.checked.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch opener(url.path) {
        case .success(let opened):
            handle = opened
        case .failure(.unreadable(let reason)):
            let aside = try Self.moveAside(url)
            onSetAside(SetAside(database: url, aside: aside, reason: reason))
            handle = try opener(url.path).get()
        case .failure(let failure):
            throw failure
        }
    }

    /// Opens `path` and reads its schema once (an open reads no page; the first statement would
    /// meet a damaged file instead). A schema this SQLite cannot parse ("malformed database
    /// schema") is an open failure and the file is kept: a newer build may have written it (the
    /// same rule as cmux-tui's `sqlite_policy::unreadable_reason`).
    static func openHandle(path: String) -> Result<OpaquePointer, Failure> {
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let code = blockingSQLiteOpen(path, &opened, flags)
        guard code == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            blockingSQLiteClose(opened)
            return .failure(.open(message))
        }
        sqlite3_busy_timeout(opened, busyTimeoutMilliseconds)
        let probe = blockingSQLiteExec(opened, "SELECT count(*) FROM sqlite_master")
        guard probe == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(opened))
            blockingSQLiteClose(opened)
            let primary = probe & 0xff
            let unreadable = (primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB) && !message.contains("malformed database schema")
            return .failure(unreadable ? .unreadable(message) : .open(message))
        }
        return .success(opened)
    }

    /// Moves the database to `<name>.corrupt` (never over an earlier one) and its `-wal`,
    /// `-journal` and `-shm` beside it; a sidecar that cannot move is removed, since SQLite would
    /// replay it into the new database.
    private static func moveAside(_ url: URL) throws -> URL {
        let manager = FileManager.checked
        let first = url.appendingPathExtension("corrupt")
        let aside = manager.fileExists(atPath: first.path) ? url.appendingPathExtension("corrupt-\(UUID().uuidString)") : first
        try manager.moveItem(at: url, to: aside)
        for suffix in ["-wal", "-journal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            guard manager.fileExists(atPath: sidecar.path) else { continue }
            do {
                try manager.moveItem(at: sidecar, to: URL(fileURLWithPath: aside.path + suffix))
            } catch {
                try manager.removeItem(at: sidecar)
            }
        }
        return aside
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
