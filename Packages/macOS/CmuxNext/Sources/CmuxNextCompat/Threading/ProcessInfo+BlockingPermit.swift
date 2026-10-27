public import Darwin

/// ``blockingSysctl(_:_:_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingSysctl(_ name: UnsafeMutablePointer<Int32>, _ count: u_int, _ old: UnsafeMutableRawPointer?,
                           _ oldLength: UnsafeMutablePointer<Int>?, _ new: UnsafeMutableRawPointer?, _ newLength: Int,
                           _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to sysctl unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return blockingCall(.systemQuery, permit, fileID: fileID, line: line) { unsafe sysctl(name, count, old, oldLength, new, newLength) }
}

/// ``blockingSysctlByName(_:_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingSysctlByName(_ name: UnsafePointer<CChar>, _ old: UnsafeMutableRawPointer?, _ oldLength: UnsafeMutablePointer<Int>?,
                                 _ new: UnsafeMutableRawPointer?, _ newLength: Int,
                                 _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to sysctlbyname unchanged, only for the call; the caller's own `unsafe`
    // states why they are valid for it.
    return blockingCall(.systemQuery, permit, fileID: fileID, line: line) { unsafe sysctlbyname(name, old, oldLength, new, newLength) }
}

/// ``blockingProcPidInfo(_:_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingProcPidInfo(_ pid: pid_t, _ flavor: Int32, _ argument: UInt64, _ buffer: UnsafeMutableRawPointer?, _ size: Int32,
                                _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to proc_pidinfo unchanged, only for the call; the caller's own `unsafe`
    // states why they are valid for it.
    return blockingCall(.systemQuery, permit, fileID: fileID, line: line) { unsafe proc_pidinfo(pid, flavor, argument, buffer, size) }
}

/// ``blockingProcPidPath(_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingProcPidPath(_ pid: pid_t, _ buffer: UnsafeMutableRawPointer, _ size: UInt32,
                                _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to the checked call unchanged, only for the call; the caller's own
    // `unsafe` states why they are valid for it.
    return unsafe checkedProcPidPath(pid, buffer, size, fileID: fileID, line: line)
}

/// ``blockingProcPidFDInfo(_:_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingProcPidFDInfo(_ pid: pid_t, _ descriptor: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer?, _ size: Int32,
                                  _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to the checked call unchanged, only for the call; the caller's own
    // `unsafe` states why they are valid for it.
    return unsafe checkedProcPidFDInfo(pid, descriptor, flavor, buffer, size, fileID: fileID, line: line)
}

/// ``blockingProcListPids(_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingProcListPids(_ type: UInt32, _ typeInfo: UInt32, _ buffer: UnsafeMutableRawPointer?, _ size: Int32,
                                 _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to the checked call unchanged, only for the call; the caller's own
    // `unsafe` states why they are valid for it.
    return unsafe checkedProcListPids(type, typeInfo, buffer, size, fileID: fileID, line: line)
}

/// ``blockingProcPidRusage(_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingProcPidRusage(_ pid: pid_t, _ flavor: Int32, _ buffer: UnsafeMutablePointer<rusage_info_t?>,
                                  _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to proc_pid_rusage unchanged, only for the call; the caller's own `unsafe`
    // states why they are valid for it.
    return blockingCall(.systemQuery, permit, fileID: fileID, line: line) { unsafe proc_pid_rusage(pid, flavor, buffer) }
}

/// ``blockingGetpwuid(_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingGetpwuid(_ uid: uid_t, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> UnsafeMutablePointer<passwd>? {
    // SAFETY: forwards the caller's pointers to getpwuid unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return unsafe blockingCall(.systemQuery, permit, fileID: fileID, line: line) { () -> UnsafeMutablePointer<passwd>? in unsafe getpwuid(uid) }
}

/// ``blockingGetpwnam(_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingGetpwnam(_ name: UnsafePointer<CChar>,
                             _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> UnsafeMutablePointer<passwd>? {
    // SAFETY: forwards the caller's pointers to getpwnam unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return unsafe blockingCall(.systemQuery, permit, fileID: fileID, line: line) { () -> UnsafeMutablePointer<passwd>? in unsafe getpwnam(name) }
}
