public import Darwin

// Checked seams over kernel and directory queries (``blockingCall(_:fileID:line:_:)``, Chrome's
// `base::ScopedBlockingCall`; Chrome's task manager samples process metrics on a may-block sequence,
// chrome/browser/task_manager/sampling/task_group_sampler.cc). Each passes its caller's
// `#fileID` and `#line`, which name the call site, and returns what the call returns. `ProcessInfo.hostName`
// and `Host.current()` get no seam: they wait on DNS, check-concurrency bans them, and `MacName` reads the
// names without it.

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
    // SAFETY: forwards the caller's pointers to sysctl unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return blockingCall(.systemQuery, fileID: fileID, line: line) { unsafe sysctl(name, count, old, oldLength, new, newLength) }
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
    // SAFETY: forwards the caller's pointers to sysctlbyname unchanged, only for the call; the caller's own `unsafe`
    // states why they are valid for it.
    return blockingCall(.systemQuery, fileID: fileID, line: line) { unsafe sysctlbyname(name, old, oldLength, new, newLength) }
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
    // SAFETY: forwards the caller's pointers to proc_pidinfo unchanged, only for the call; the caller's own `unsafe`
    // states why they are valid for it.
    return blockingCall(.systemQuery, fileID: fileID, line: line) { unsafe proc_pidinfo(pid, flavor, argument, buffer, size) }
}

/// Reads a process's executable path, like `proc_pidpath`, as a checked blocking call (kind
/// ``BlockingKind/systemQuery``).
///
/// - Parameters:
///   - pid: The process.
///   - buffer: Receives the path (`PROC_PIDPATHINFO_MAXSIZE` bytes).
///   - size: The buffer's size.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The path's length, or 0 or less on an error.
@inlinable
public func blockingProcPidPath(_ pid: pid_t, _ buffer: UnsafeMutableRawPointer, _ size: UInt32,
                                fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to proc_pidpath unchanged, only for the call; the caller's own `unsafe`
    // states why they are valid for it.
    return blockingCall(.systemQuery, fileID: fileID, line: line) { unsafe proc_pidpath(pid, buffer, size) }
}

/// Reads a process's descriptor information, like `proc_pidfdinfo`, as a checked blocking call (kind
/// ``BlockingKind/systemQuery``).
///
/// - Parameters:
///   - pid: The process.
///   - descriptor: Its descriptor.
///   - flavor: The `PROC_PIDFD` flavor.
///   - buffer: Receives the information.
///   - size: The buffer's size.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The bytes written, or 0 or less on an error.
@inlinable
public func blockingProcPidFDInfo(_ pid: pid_t, _ descriptor: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer?, _ size: Int32,
                                  fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to proc_pidfdinfo unchanged, only for the call; the caller's own `unsafe`
    // states why they are valid for it.
    return blockingCall(.systemQuery, fileID: fileID, line: line) { unsafe proc_pidfdinfo(pid, descriptor, flavor, buffer, size) }
}

/// Lists process ids, like `proc_listpids`, as a checked blocking call (kind ``BlockingKind/systemQuery``).
///
/// - Parameters:
///   - type: Which processes (`PROC_UID_ONLY`).
///   - typeInfo: The type's argument (the uid).
///   - buffer: Receives the pids, or nil to ask the size.
///   - size: The buffer's size in bytes.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The bytes written (or needed), or 0 or less on an error.
@inlinable
public func blockingProcListPids(_ type: UInt32, _ typeInfo: UInt32, _ buffer: UnsafeMutableRawPointer?, _ size: Int32,
                                 fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to proc_listpids unchanged, only for the call; the caller's own `unsafe`
    // states why they are valid for it.
    return blockingCall(.systemQuery, fileID: fileID, line: line) { unsafe proc_listpids(type, typeInfo, buffer, size) }
}

/// Reads a process's resource usage, like `proc_pid_rusage`, as a checked blocking call (kind
/// ``BlockingKind/systemQuery``).
///
/// - Parameters:
///   - pid: The process.
///   - flavor: The `RUSAGE_INFO` version.
///   - buffer: Receives the usage (a `rusage_info_v4` for `RUSAGE_INFO_V4`, rebound).
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: 0, or -1 with `errno` set.
@inlinable
public func blockingProcPidRusage(_ pid: pid_t, _ flavor: Int32, _ buffer: UnsafeMutablePointer<rusage_info_t?>,
                                  fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to proc_pid_rusage unchanged, only for the call; the caller's own `unsafe`
    // states why they are valid for it.
    return blockingCall(.systemQuery, fileID: fileID, line: line) { unsafe proc_pid_rusage(pid, flavor, buffer) }
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
    // SAFETY: forwards the caller's pointers to getpwuid unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return unsafe blockingCall(.systemQuery, fileID: fileID, line: line) { () -> UnsafeMutablePointer<passwd>? in unsafe getpwuid(uid) }
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
    // SAFETY: forwards the caller's pointers to getpwnam unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return unsafe blockingCall(.systemQuery, fileID: fileID, line: line) { () -> UnsafeMutablePointer<passwd>? in unsafe getpwnam(name) }
}
