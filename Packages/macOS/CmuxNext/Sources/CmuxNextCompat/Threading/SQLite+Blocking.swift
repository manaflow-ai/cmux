#if canImport(SQLite3)
public import SQLite3

// Checked seams over the SQLite calls that touch the database file (``blockingCall(_:fileID:line:_:)``,
// Chrome's `base::ScopedBlockingCall`; Chrome's sql::Database asserts it may block on every statement,
// sql/database.cc `AssertIOAllowed`). They take the C arguments in the C order and return the result code.

/// Opens a database, like `sqlite3_open_v2`, as a checked blocking call (kind ``BlockingKind/sqlite``).
///
/// - Parameters:
///   - path: The database file.
///   - database: Receives the connection (close it even when the open fails).
///   - flags: `SQLITE_OPEN_` flags.
///   - vfs: The VFS name, or nil.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The SQLite result code.
@inlinable
public func blockingSQLiteOpen(_ path: UnsafePointer<CChar>, _ database: UnsafeMutablePointer<OpaquePointer?>, _ flags: Int32,
                               _ vfs: UnsafePointer<CChar>? = nil, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to sqlite3_open_v2 unchanged, only for the call; the caller's own `unsafe`
    // states why they are valid for it.
    return blockingCall(.sqlite, fileID: fileID, line: line) { unsafe sqlite3_open_v2(path, database, flags, vfs) }
}

/// Compiles a statement, like `sqlite3_prepare_v2`, as a checked blocking call (kind ``BlockingKind/sqlite``):
/// it reads the schema and waits out another connection's lock.
///
/// - Parameters:
///   - database: The connection.
///   - sql: The statement text.
///   - byteCount: The text's length in bytes, or -1 up to its NUL.
///   - statement: Receives the statement.
///   - tail: Receives the rest of the text after the first statement, or nil.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The SQLite result code.
@inlinable
public func blockingSQLitePrepare(_ database: OpaquePointer?, _ sql: UnsafePointer<CChar>, _ byteCount: Int32,
                                  _ statement: UnsafeMutablePointer<OpaquePointer?>, _ tail: UnsafeMutablePointer<UnsafePointer<CChar>?>?,
                                  fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to sqlite3_prepare_v2 unchanged, only for the call; the caller's own
    // `unsafe` states why they are valid for it.
    return blockingCall(.sqlite, fileID: fileID, line: line) { unsafe sqlite3_prepare_v2(database, sql, byteCount, statement, tail) }
}

/// Runs a statement one step, like `sqlite3_step`, as a checked blocking call (kind ``BlockingKind/sqlite``).
///
/// - Parameters:
///   - statement: The statement.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The SQLite result code (`SQLITE_ROW`, `SQLITE_DONE` or an error).
@inlinable
public func blockingSQLiteStep(_ statement: OpaquePointer?, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to sqlite3_step unchanged, only for the call; the caller's own `unsafe`
    // states why they are valid for it.
    return blockingCall(.sqlite, fileID: fileID, line: line) { unsafe sqlite3_step(statement) }
}

/// Runs SQL text with no result rows, like `sqlite3_exec` with no callback, as a checked blocking call (kind
/// ``BlockingKind/sqlite``).
///
/// - Parameters:
///   - database: The connection.
///   - sql: The statements.
///   - errorMessage: Receives the error text (free it with `sqlite3_free`), or nil.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The SQLite result code.
@inlinable
public func blockingSQLiteExec(_ database: OpaquePointer?, _ sql: UnsafePointer<CChar>,
                               _ errorMessage: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil,
                               fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to sqlite3_exec unchanged, only for the call; the caller's own `unsafe`
    // states why they are valid for it.
    return blockingCall(.sqlite, fileID: fileID, line: line) { unsafe sqlite3_exec(database, sql, nil, nil, errorMessage) }
}

/// Closes a connection, like `sqlite3_close`, as a checked blocking call (kind ``BlockingKind/sqlite``): it
/// checkpoints the WAL when it is the last connection.
///
/// - Parameters:
///   - database: The connection.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The SQLite result code.
@inlinable @discardableResult
public func blockingSQLiteClose(_ database: OpaquePointer?, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to sqlite3_close unchanged, only for the call; the caller's own `unsafe`
    // states why they are valid for it.
    return blockingCall(.sqlite, fileID: fileID, line: line) { unsafe sqlite3_close(database) }
}

/// Closes a connection, like `sqlite3_close_v2`, as a checked blocking call (kind ``BlockingKind/sqlite``): it
/// checkpoints the WAL when it is the last connection.
///
/// - Parameters:
///   - database: The connection.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The SQLite result code.
@inlinable @discardableResult
public func blockingSQLiteCloseV2(_ database: OpaquePointer?, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to sqlite3_close_v2 unchanged, only for the call; the caller's own
    // `unsafe` states why they are valid for it.
    return blockingCall(.sqlite, fileID: fileID, line: line) { unsafe sqlite3_close_v2(database) }
}

/// Copies pages of a backup, like `sqlite3_backup_step`, as a checked blocking call (kind ``BlockingKind/sqlite``):
/// with -1 it reads the whole source database and writes the whole copy.
///
/// - Parameters:
///   - backup: The backup (`sqlite3_backup_init`).
///   - pages: How many pages to copy, or -1 for all.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The SQLite result code (`SQLITE_DONE` when the copy is complete).
@inlinable
public func blockingSQLiteBackupStep(_ backup: OpaquePointer?, _ pages: Int32,
                                     fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to sqlite3_backup_step unchanged, only for the call; the caller's own
    // `unsafe` states why they are valid for it.
    return blockingCall(.sqlite, fileID: fileID, line: line) { unsafe sqlite3_backup_step(backup, pages) }
}
#endif
