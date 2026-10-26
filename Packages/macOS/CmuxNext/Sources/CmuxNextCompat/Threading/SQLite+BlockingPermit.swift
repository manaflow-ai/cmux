public import SQLite3

/// ``blockingSQLiteOpen(_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingSQLiteOpen(_ path: UnsafePointer<CChar>, _ database: UnsafeMutablePointer<OpaquePointer?>, _ flags: Int32,
                               _ permit: borrowing BlockingPermit, _ vfs: UnsafePointer<CChar>? = nil, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.sqlite, permit, fileID: fileID, line: line) { sqlite3_open_v2(path, database, flags, vfs) }
}

/// ``blockingSQLitePrepare(_:_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingSQLitePrepare(_ database: OpaquePointer?, _ sql: UnsafePointer<CChar>, _ byteCount: Int32,
                                  _ statement: UnsafeMutablePointer<OpaquePointer?>, _ tail: UnsafeMutablePointer<UnsafePointer<CChar>?>?,
                                  _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.sqlite, permit, fileID: fileID, line: line) { sqlite3_prepare_v2(database, sql, byteCount, statement, tail) }
}

/// ``blockingSQLiteStep(_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingSQLiteStep(_ statement: OpaquePointer?, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.sqlite, permit, fileID: fileID, line: line) { sqlite3_step(statement) }
}

/// ``blockingSQLiteExec(_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingSQLiteExec(_ database: OpaquePointer?, _ sql: UnsafePointer<CChar>,
                               _ permit: borrowing BlockingPermit, _ errorMessage: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil,
                               fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.sqlite, permit, fileID: fileID, line: line) { sqlite3_exec(database, sql, nil, nil, errorMessage) }
}

/// ``blockingSQLiteClose(_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable @discardableResult
public func blockingSQLiteClose(_ database: OpaquePointer?, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.sqlite, permit, fileID: fileID, line: line) { sqlite3_close(database) }
}

/// ``blockingSQLiteCloseV2(_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable @discardableResult
public func blockingSQLiteCloseV2(_ database: OpaquePointer?, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.sqlite, permit, fileID: fileID, line: line) { sqlite3_close_v2(database) }
}

/// ``blockingSQLiteBackupStep(_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingSQLiteBackupStep(_ backup: OpaquePointer?, _ pages: Int32,
                                     _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.sqlite, permit, fileID: fileID, line: line) { sqlite3_backup_step(backup, pages) }
}
