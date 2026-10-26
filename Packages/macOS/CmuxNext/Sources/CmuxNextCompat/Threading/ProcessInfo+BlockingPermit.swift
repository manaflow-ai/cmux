public import Darwin

/// ``blockingSysctl(_:_:_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingSysctl(_ name: UnsafeMutablePointer<Int32>, _ count: u_int, _ old: UnsafeMutableRawPointer?,
                           _ oldLength: UnsafeMutablePointer<Int>?, _ new: UnsafeMutableRawPointer?, _ newLength: Int,
                           _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.systemQuery, permit, fileID: fileID, line: line) { sysctl(name, count, old, oldLength, new, newLength) }
}

/// ``blockingSysctlByName(_:_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingSysctlByName(_ name: UnsafePointer<CChar>, _ old: UnsafeMutableRawPointer?, _ oldLength: UnsafeMutablePointer<Int>?,
                                 _ new: UnsafeMutableRawPointer?, _ newLength: Int,
                                 _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.systemQuery, permit, fileID: fileID, line: line) { sysctlbyname(name, old, oldLength, new, newLength) }
}

/// ``blockingProcPidInfo(_:_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingProcPidInfo(_ pid: pid_t, _ flavor: Int32, _ argument: UInt64, _ buffer: UnsafeMutableRawPointer?, _ size: Int32,
                                _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.systemQuery, permit, fileID: fileID, line: line) { proc_pidinfo(pid, flavor, argument, buffer, size) }
}

/// ``blockingProcPidPath(_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingProcPidPath(_ pid: pid_t, _ buffer: UnsafeMutableRawPointer, _ size: UInt32,
                                _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    checkedProcPidPath(pid, buffer, size, fileID: fileID, line: line)
}

/// ``blockingProcPidFDInfo(_:_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingProcPidFDInfo(_ pid: pid_t, _ descriptor: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer?, _ size: Int32,
                                  _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    checkedProcPidFDInfo(pid, descriptor, flavor, buffer, size, fileID: fileID, line: line)
}

/// ``blockingProcListPids(_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingProcListPids(_ type: UInt32, _ typeInfo: UInt32, _ buffer: UnsafeMutableRawPointer?, _ size: Int32,
                                 _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    checkedProcListPids(type, typeInfo, buffer, size, fileID: fileID, line: line)
}

/// ``blockingProcPidRusage(_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingProcPidRusage(_ pid: pid_t, _ flavor: Int32, _ buffer: UnsafeMutablePointer<rusage_info_t?>,
                                  _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.systemQuery, permit, fileID: fileID, line: line) { proc_pid_rusage(pid, flavor, buffer) }
}

/// ``blockingGetpwuid(_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingGetpwuid(_ uid: uid_t, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> UnsafeMutablePointer<passwd>? {
    return blockingCall(.systemQuery, permit, fileID: fileID, line: line) { () -> UnsafeMutablePointer<passwd>? in getpwuid(uid) }
}

/// ``blockingGetpwnam(_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingGetpwnam(_ name: UnsafePointer<CChar>,
                             _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> UnsafeMutablePointer<passwd>? {
    return blockingCall(.systemQuery, permit, fileID: fileID, line: line) { () -> UnsafeMutablePointer<passwd>? in getpwnam(name) }
}
