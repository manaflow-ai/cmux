public import Darwin

/// ``blockingOpen(_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingOpen(_ path: UnsafePointer<CChar>, _ flags: Int32, _ permit: borrowing BlockingPermit, _ mode: mode_t = 0,
                         fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.fileIO, permit, fileID: fileID, line: line) { Darwin.open(path, flags, mode) }
}

/// ``blockingPread(_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingPread(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int, _ offset: off_t,
                          _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int {
    return blockingCall(.fileIO, permit, fileID: fileID, line: line) { Darwin.pread(descriptor, buffer, count, offset) }
}

/// ``blockingPwrite(_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingPwrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int, _ offset: off_t,
                           _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int {
    return blockingCall(.fileIO, permit, fileID: fileID, line: line) { Darwin.pwrite(descriptor, buffer, count, offset) }
}

/// ``blockingFsync(_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingFsync(_ descriptor: Int32, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.fileIO, permit, fileID: fileID, line: line) { Darwin.fsync(descriptor) }
}

/// ``blockingFlock(_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingFlock(_ descriptor: Int32, _ operation: Int32, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.fileIO, permit, fileID: fileID, line: line) { () -> Int32 in flock(descriptor, operation) }
}

/// ``blockingFtruncate(_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingFtruncate(_ descriptor: Int32, _ length: off_t, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.fileIO, permit, fileID: fileID, line: line) { Darwin.ftruncate(descriptor, length) }
}

/// ``blockingRename(_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingRename(_ from: UnsafePointer<CChar>, _ to: UnsafePointer<CChar>,
                           _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.fsMetadata, permit, fileID: fileID, line: line) { Darwin.rename(from, to) }
}

/// ``blockingUnlink(_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingUnlink(_ path: UnsafePointer<CChar>, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.fsMetadata, permit, fileID: fileID, line: line) { Darwin.unlink(path) }
}

/// ``blockingStat(_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingStat(_ path: UnsafePointer<CChar>, _ info: UnsafeMutablePointer<stat>,
                         _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.fsMetadata, permit, fileID: fileID, line: line) { () -> Int32 in stat(path, info) }
}

/// ``blockingLstat(_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingLstat(_ path: UnsafePointer<CChar>, _ info: UnsafeMutablePointer<stat>,
                          _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.fsMetadata, permit, fileID: fileID, line: line) { Darwin.lstat(path, info) }
}

/// ``blockingRealpath(_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingRealpath(_ path: UnsafePointer<CChar>, _ resolved: UnsafeMutablePointer<CChar>?,
                             _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> UnsafeMutablePointer<CChar>? {
    return blockingCall(.fsMetadata, permit, fileID: fileID, line: line) { () -> UnsafeMutablePointer<CChar>? in Darwin.realpath(path, resolved) }
}

/// ``blockingAccess(_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingAccess(_ path: UnsafePointer<CChar>, _ mode: Int32, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.fsMetadata, permit, fileID: fileID, line: line) { Darwin.access(path, mode) }
}

/// ``blockingChmod(_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingChmod(_ path: UnsafePointer<CChar>, _ mode: mode_t, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.fsMetadata, permit, fileID: fileID, line: line) { Darwin.chmod(path, mode) }
}

/// ``blockingMkdir(_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingMkdir(_ path: UnsafePointer<CChar>, _ mode: mode_t, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.fsMetadata, permit, fileID: fileID, line: line) { Darwin.mkdir(path, mode) }
}

/// ``blockingRmdir(_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingRmdir(_ path: UnsafePointer<CChar>, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.fsMetadata, permit, fileID: fileID, line: line) { Darwin.rmdir(path) }
}

/// ``blockingWaitpid(_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingWaitpid(_ pid: pid_t, _ status: UnsafeMutablePointer<Int32>?, _ options: Int32,
                            _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> pid_t {
    return blockingCall(.processReap, permit, fileID: fileID, line: line) { Darwin.waitpid(pid, status, options) }
}

/// ``blockingWaitid(_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingWaitid(_ type: idtype_t, _ id: id_t, _ info: UnsafeMutablePointer<siginfo_t>, _ options: Int32,
                           _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.processReap, permit, fileID: fileID, line: line) { Darwin.waitid(type, id, info, options) }
}
