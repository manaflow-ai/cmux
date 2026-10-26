public import Darwin

// Checked seams over kernel and directory queries (``blockingCall(_:fileID:line:_:)``, Chrome's
// `base::ScopedBlockingCall`; Chrome's task manager samples process metrics on a may-block sequence,
// chrome/browser/task_manager/sampling/task_group_sampler.cc). Each passes its caller's
// `#fileID` and `#line`, which name the call site, and returns what the call returns. `ProcessInfo.hostName`
// and `Host.current()` get no seam: they wait on DNS, check-concurrency bans them, and `MacName` reads the
// names without it. `proc_pidpath` and `proc_listpids` get no seam either: cmux-next never scans or
// identifies processes (check-no-process-scan.py, plans/cmux-next/pty-holder.md section 4).

/// Reads or writes a kernel value by MIB, like `sysctl(3)`, as a checked blocking call (kind
/// ``BlockingKind/systemQuery``).
///
/// - Parameters:
///   - name: The MIB.
///   - count: The MIB's length.
///   - old: Receives the value, or nil to ask its size.
///   - oldLength: The buffer's size in, the value's size out.
///   - new: A new value, or nil.
///   - newLength: The new value's size.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `sysctl` returns.
@inlinable
public func blockingSysctl(_ name: UnsafeMutablePointer<Int32>, _ count: u_int, _ old: UnsafeMutableRawPointer?,
                           _ oldLength: UnsafeMutablePointer<Int>?, _ new: UnsafeMutableRawPointer?, _ newLength: Int,
                           fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.systemQuery, fileID: fileID, line: line) { sysctl(name, count, old, oldLength, new, newLength) }
}

/// Reads or writes a kernel value by name, like `sysctlbyname(3)`, as a checked blocking call (kind
/// ``BlockingKind/systemQuery``).
///
/// - Parameters:
///   - name: The value's name (`"hw.memsize"`).
///   - old: Receives the value, or nil to ask its size.
///   - oldLength: The buffer's size in, the value's size out.
///   - new: A new value, or nil.
///   - newLength: The new value's size.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `sysctlbyname` returns.
@inlinable
public func blockingSysctlByName(_ name: UnsafePointer<CChar>, _ old: UnsafeMutableRawPointer?, _ oldLength: UnsafeMutablePointer<Int>?,
                                 _ new: UnsafeMutableRawPointer?, _ newLength: Int,
                                 fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.systemQuery, fileID: fileID, line: line) { sysctlbyname(name, old, oldLength, new, newLength) }
}

/// Reads a process's information, like `proc_pidinfo`, as a checked blocking call (kind
/// ``BlockingKind/systemQuery``).
///
/// - Parameters:
///   - pid: The process.
///   - flavor: The `PROC_PID` flavor.
///   - argument: The flavor's argument.
///   - buffer: Receives the information, or nil to ask its size.
///   - size: The buffer's size.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The bytes written, or 0 or less on an error.
@inlinable
public func blockingProcPidInfo(_ pid: pid_t, _ flavor: Int32, _ argument: UInt64, _ buffer: UnsafeMutableRawPointer?, _ size: Int32,
                                fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.systemQuery, fileID: fileID, line: line) { proc_pidinfo(pid, flavor, argument, buffer, size) }
}

/// Reads a user's account entry, like `getpwuid(3)`, as a checked blocking call (kind
/// ``BlockingKind/systemQuery``): it waits for opendirectoryd, which can ask a directory server.
///
/// - Parameters:
///   - uid: The user.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The entry (valid until the next `getpw*` call on any thread), or nil.
@inlinable
public func blockingGetpwuid(_ uid: uid_t, fileID: StaticString = #fileID, line: UInt = #line) -> UnsafeMutablePointer<passwd>? {
    return blockingCall(.systemQuery, fileID: fileID, line: line) { () -> UnsafeMutablePointer<passwd>? in getpwuid(uid) }
}

/// Reads a user's account entry by name, like `getpwnam(3)`, as a checked blocking call (kind
/// ``BlockingKind/systemQuery``): it waits for opendirectoryd.
///
/// - Parameters:
///   - name: The user name.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The entry (valid until the next `getpw*` call on any thread), or nil.
@inlinable
public func blockingGetpwnam(_ name: UnsafePointer<CChar>,
                             fileID: StaticString = #fileID, line: UInt = #line) -> UnsafeMutablePointer<passwd>? {
    return blockingCall(.systemQuery, fileID: fileID, line: line) { () -> UnsafeMutablePointer<passwd>? in getpwnam(name) }
}
