public import Darwin

/// ``blockingOpen(_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingOpen(_ path: UnsafePointer<CChar>, _ flags: Int32, _ permit: borrowing BlockingPermit, _ mode: mode_t = 0,
                         fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to open unchanged, only for the call; the caller's own `unsafe` states why
    // they are valid for it.
    return blockingCall(.fileIO, permit, fileID: fileID, line: line) { unsafe Darwin.open(path, flags, mode) }
}

/// ``blockingPread(_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingPread(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int, _ offset: off_t,
                          _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int {
    // SAFETY: forwards the caller's pointers to pread unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return blockingCall(.fileIO, permit, fileID: fileID, line: line) { unsafe Darwin.pread(descriptor, buffer, count, offset) }
}

/// ``blockingPwrite(_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingPwrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int, _ offset: off_t,
                           _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int {
    // SAFETY: forwards the caller's pointers to pwrite unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return blockingCall(.fileIO, permit, fileID: fileID, line: line) { unsafe Darwin.pwrite(descriptor, buffer, count, offset) }
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
    // SAFETY: forwards the caller's pointers to rename unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return blockingCall(.fsMetadata, permit, fileID: fileID, line: line) { unsafe Darwin.rename(from, to) }
}

/// ``blockingUnlink(_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingUnlink(_ path: UnsafePointer<CChar>, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to unlink unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return blockingCall(.fsMetadata, permit, fileID: fileID, line: line) { unsafe Darwin.unlink(path) }
}

/// ``blockingStat(_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingStat(_ path: UnsafePointer<CChar>, _ info: UnsafeMutablePointer<stat>,
                         _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to stat unchanged, only for the call; the caller's own `unsafe` states why
    // they are valid for it.
    return blockingCall(.fsMetadata, permit, fileID: fileID, line: line) { () -> Int32 in unsafe stat(path, info) }
}

/// ``blockingLstat(_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingLstat(_ path: UnsafePointer<CChar>, _ info: UnsafeMutablePointer<stat>,
                          _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to lstat unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return blockingCall(.fsMetadata, permit, fileID: fileID, line: line) { unsafe Darwin.lstat(path, info) }
}

/// ``blockingRealpath(_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingRealpath(_ path: UnsafePointer<CChar>, _ resolved: UnsafeMutablePointer<CChar>?,
                             _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> UnsafeMutablePointer<CChar>? {
    // SAFETY: forwards the caller's pointers to realpath unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return unsafe blockingCall(.fsMetadata, permit, fileID: fileID, line: line) { () -> UnsafeMutablePointer<CChar>? in unsafe Darwin.realpath(path, resolved) }
}

/// ``blockingAccess(_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingAccess(_ path: UnsafePointer<CChar>, _ mode: Int32, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to access unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return blockingCall(.fsMetadata, permit, fileID: fileID, line: line) { unsafe Darwin.access(path, mode) }
}

/// ``blockingChmod(_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingChmod(_ path: UnsafePointer<CChar>, _ mode: mode_t, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to chmod unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return blockingCall(.fsMetadata, permit, fileID: fileID, line: line) { unsafe Darwin.chmod(path, mode) }
}

/// ``blockingMkdir(_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingMkdir(_ path: UnsafePointer<CChar>, _ mode: mode_t, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to mkdir unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return blockingCall(.fsMetadata, permit, fileID: fileID, line: line) { unsafe Darwin.mkdir(path, mode) }
}

/// ``blockingRmdir(_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingRmdir(_ path: UnsafePointer<CChar>, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to rmdir unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return blockingCall(.fsMetadata, permit, fileID: fileID, line: line) { unsafe Darwin.rmdir(path) }
}

/// ``blockingWaitpid(_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingWaitpid(_ pid: pid_t, _ status: UnsafeMutablePointer<Int32>?, _ options: Int32,
                            _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> pid_t {
    // SAFETY: forwards the caller's pointers to waitpid unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return blockingCall(.processReap, permit, fileID: fileID, line: line) { unsafe Darwin.waitpid(pid, status, options) }
}

/// ``blockingWaitid(_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingWaitid(_ type: idtype_t, _ id: id_t, _ info: UnsafeMutablePointer<siginfo_t>, _ options: Int32,
                           _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to waitid unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return blockingCall(.processReap, permit, fileID: fileID, line: line) { unsafe Darwin.waitid(type, id, info, options) }
}
