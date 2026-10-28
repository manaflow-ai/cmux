public import Darwin

// Checked seams over the POSIX file calls (``blockingCall(_:fileID:line:_:)``, Chrome's
// `base::ScopedBlockingCall` in base/files/file_posix.cc and base/files/file_util_posix.cc). Each passes
// its caller's `#fileID` and `#line`, which name the call site, and returns what the call returns.
// Descriptor reads and writes of a socket or pipe are `blockingRead` / `blockingWrite` (BlockingDescriptorIO).
// `flock` and `stat` are called unqualified with a typed closure: `Darwin.flock` and `Darwin.stat` name the structs.

/// Opens a file, like `open(2)`, as a checked blocking call (kind ``BlockingKind/fileIO``).
///
/// - Parameters:
///   - path: The file.
///   - flags: `O_` flags.
///   - mode: The new file's mode, with `O_CREAT`.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The descriptor, or -1 with `errno` set.
@available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingOpen(_ path: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t = 0,
                         fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to open unchanged, only for the call; the caller's own `unsafe` states why
    // they are valid for it.
    return blockingCall(.fileIO, fileID: fileID, line: line) { unsafe Darwin.open(path, flags, mode) }
}

/// Reads at an offset, like `pread(2)`, as a checked blocking call (kind ``BlockingKind/fileIO``).
///
/// - Parameters:
///   - descriptor: The file.
///   - buffer: Where the bytes go.
///   - count: The most bytes.
///   - offset: Where to read.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `pread(2)` returns.
@available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingPread(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int, _ offset: off_t,
                          fileID: StaticString = #fileID, line: UInt = #line) -> Int {
    // SAFETY: forwards the caller's pointers to pread unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return blockingCall(.fileIO, fileID: fileID, line: line) { unsafe Darwin.pread(descriptor, buffer, count, offset) }
}

/// Writes at an offset, like `pwrite(2)`, as a checked blocking call (kind ``BlockingKind/fileIO``).
///
/// - Parameters:
///   - descriptor: The file.
///   - buffer: The bytes.
///   - count: How many.
///   - offset: Where to write.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `pwrite(2)` returns.
@available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingPwrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int, _ offset: off_t,
                           fileID: StaticString = #fileID, line: UInt = #line) -> Int {
    // SAFETY: forwards the caller's pointers to pwrite unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return blockingCall(.fileIO, fileID: fileID, line: line) { unsafe Darwin.pwrite(descriptor, buffer, count, offset) }
}

/// Flushes a file to the disk, like `fsync(2)`, as a checked blocking call (kind ``BlockingKind/fileIO``).
///
/// - Parameters:
///   - descriptor: The file.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `fsync(2)` returns.
@available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingFsync(_ descriptor: Int32, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.fileIO, fileID: fileID, line: line) { Darwin.fsync(descriptor) }
}

/// Takes or drops an advisory lock, like `flock(2)`, as a checked blocking call (kind ``BlockingKind/fileIO``,
/// as Chrome's `base::File::Lock` in base/files/file_posix.cc): without `LOCK_NB` it waits while another process
/// holds the lock.
///
/// - Parameters:
///   - descriptor: The file.
///   - operation: `LOCK_` flags.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `flock(2)` returns.
@available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingFlock(_ descriptor: Int32, _ operation: Int32, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.fileIO, fileID: fileID, line: line) { () -> Int32 in flock(descriptor, operation) }
}

/// Sets a file's length, like `ftruncate(2)`, as a checked blocking call (kind ``BlockingKind/fileIO``).
///
/// - Parameters:
///   - descriptor: The file.
///   - length: The new length.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `ftruncate(2)` returns.
@available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingFtruncate(_ descriptor: Int32, _ length: off_t, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.fileIO, fileID: fileID, line: line) { Darwin.ftruncate(descriptor, length) }
}

/// Renames a file, like `rename(2)`, as a checked blocking call (kind ``BlockingKind/fsMetadata``).
///
/// - Parameters:
///   - from: The old path.
///   - to: The new path.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `rename(2)` returns.
@available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingRename(_ from: UnsafePointer<CChar>, _ to: UnsafePointer<CChar>,
                           fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to rename unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return blockingCall(.fsMetadata, fileID: fileID, line: line) { unsafe Darwin.rename(from, to) }
}

/// Removes a file, like `unlink(2)`, as a checked blocking call (kind ``BlockingKind/fsMetadata``).
///
/// - Parameters:
///   - path: The file.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `unlink(2)` returns.
@available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingUnlink(_ path: UnsafePointer<CChar>, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to unlink unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return blockingCall(.fsMetadata, fileID: fileID, line: line) { unsafe Darwin.unlink(path) }
}

/// Reads a file's status, like `stat(2)`, as a checked blocking call (kind ``BlockingKind/fsMetadata``).
///
/// - Parameters:
///   - path: The file.
///   - info: Receives the status.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `stat(2)` returns.
@available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingStat(_ path: UnsafePointer<CChar>, _ info: UnsafeMutablePointer<stat>,
                         fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to stat unchanged, only for the call; the caller's own `unsafe` states why
    // they are valid for it.
    return blockingCall(.fsMetadata, fileID: fileID, line: line) { () -> Int32 in unsafe stat(path, info) }
}

/// Reads a link's own status, like `lstat(2)`, as a checked blocking call (kind ``BlockingKind/fsMetadata``).
///
/// - Parameters:
///   - path: The file.
///   - info: Receives the status.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `lstat(2)` returns.
@available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingLstat(_ path: UnsafePointer<CChar>, _ info: UnsafeMutablePointer<stat>,
                          fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to lstat unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return blockingCall(.fsMetadata, fileID: fileID, line: line) { unsafe Darwin.lstat(path, info) }
}

/// Resolves a path, like `realpath(3)`, as a checked blocking call (kind ``BlockingKind/fsMetadata``): it
/// reads every link on the way.
///
/// - Parameters:
///   - path: The path.
///   - resolved: A `PATH_MAX` buffer, or nil to have one allocated (free it).
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The resolved path, or nil with `errno` set.
@available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingRealpath(_ path: UnsafePointer<CChar>, _ resolved: UnsafeMutablePointer<CChar>?,
                             fileID: StaticString = #fileID, line: UInt = #line) -> UnsafeMutablePointer<CChar>? {
    // SAFETY: forwards the caller's pointers to realpath unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return unsafe blockingCall(.fsMetadata, fileID: fileID, line: line) { () -> UnsafeMutablePointer<CChar>? in unsafe Darwin.realpath(path, resolved) }
}

/// Checks access to a file, like `access(2)`, as a checked blocking call (kind ``BlockingKind/fsMetadata``).
///
/// - Parameters:
///   - path: The file.
///   - mode: `F_OK`, or `R_OK` / `W_OK` / `X_OK`.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `access(2)` returns.
@available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingAccess(_ path: UnsafePointer<CChar>, _ mode: Int32, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to access unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return blockingCall(.fsMetadata, fileID: fileID, line: line) { unsafe Darwin.access(path, mode) }
}

/// Changes a file's mode, like `chmod(2)`, as a checked blocking call (kind ``BlockingKind/fsMetadata``).
///
/// - Parameters:
///   - path: The file.
///   - mode: The new mode.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `chmod(2)` returns.
@available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingChmod(_ path: UnsafePointer<CChar>, _ mode: mode_t, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to chmod unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return blockingCall(.fsMetadata, fileID: fileID, line: line) { unsafe Darwin.chmod(path, mode) }
}

/// Makes a directory, like `mkdir(2)`, as a checked blocking call (kind ``BlockingKind/fsMetadata``).
///
/// - Parameters:
///   - path: The directory.
///   - mode: Its mode.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `mkdir(2)` returns.
@available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingMkdir(_ path: UnsafePointer<CChar>, _ mode: mode_t, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to mkdir unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return blockingCall(.fsMetadata, fileID: fileID, line: line) { unsafe Darwin.mkdir(path, mode) }
}

/// Removes an empty directory, like `rmdir(2)`, as a checked blocking call (kind ``BlockingKind/fsMetadata``).
///
/// - Parameters:
///   - path: The directory.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `rmdir(2)` returns.
@available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingRmdir(_ path: UnsafePointer<CChar>, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to rmdir unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return blockingCall(.fsMetadata, fileID: fileID, line: line) { unsafe Darwin.rmdir(path) }
}

/// Waits for a child, like `waitpid(2)`, as a checked blocking call (kind ``BlockingKind/processReap``).
/// A `WNOHANG` poll does not wait: call `waitpid` itself for that, from a process-exit source's handler.
///
/// - Parameters:
///   - pid: The child.
///   - status: Receives its exit status.
///   - options: `waitpid` options.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The reaped child's pid, 0, or -1 with `errno` set.
@available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingWaitpid(_ pid: pid_t, _ status: UnsafeMutablePointer<Int32>?, _ options: Int32,
                            fileID: StaticString = #fileID, line: UInt = #line) -> pid_t {
    // SAFETY: forwards the caller's pointers to waitpid unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return blockingCall(.processReap, fileID: fileID, line: line) { unsafe Darwin.waitpid(pid, status, options) }
}

/// Waits for a child's state change, like `waitid(2)`, as a checked blocking call (kind
/// ``BlockingKind/processReap``). A `WNOHANG` poll does not wait: call `waitid` itself for that.
///
/// - Parameters:
///   - type: Which id `id` is (`P_PID`).
///   - id: The child.
///   - info: Receives the child's state.
///   - options: `waitid` options (`WEXITED`, `WNOWAIT`).
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `waitid(2)` returns.
@available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingWaitid(_ type: idtype_t, _ id: id_t, _ info: UnsafeMutablePointer<siginfo_t>, _ options: Int32,
                           fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to waitid unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return blockingCall(.processReap, fileID: fileID, line: line) { unsafe Darwin.waitid(type, id, info, options) }
}
