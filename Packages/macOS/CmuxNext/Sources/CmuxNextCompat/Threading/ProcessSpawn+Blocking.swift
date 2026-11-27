#if canImport(Darwin)
public import Darwin
#else
public import Glibc
#endif

/// Spawns a process, like `posix_spawn`, as a checked blocking call
/// (``assertBlockingAllowed(_:fileID:line:)``): a spawn on the main thread stalls it. Spawn from an actor
/// or a `@concurrent` function.
///
/// - Parameters:
///   - pid: Receives the child's process id.
///   - path: The executable.
///   - fileActions: `posix_spawn` file actions.
///   - attributes: `posix_spawn` attributes.
///   - argv: The arguments, ending with nil.
///   - envp: The environment, ending with nil.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `posix_spawn` returns (0, or an error number).
#if canImport(Darwin)
public typealias PosixSpawnFileActions = posix_spawn_file_actions_t?
public typealias PosixSpawnAttributes = posix_spawnattr_t?
#else
public typealias PosixSpawnFileActions = posix_spawn_file_actions_t
public typealias PosixSpawnAttributes = posix_spawnattr_t
#endif

@inlinable
public func blockingPosixSpawn(_ pid: UnsafeMutablePointer<pid_t>?, _ path: UnsafePointer<CChar>,
                               _ fileActions: UnsafePointer<PosixSpawnFileActions>?,
                               _ attributes: UnsafePointer<PosixSpawnAttributes>?,
                               _ argv: UnsafePointer<UnsafeMutablePointer<CChar>?>,
                               _ envp: UnsafePointer<UnsafeMutablePointer<CChar>?>?,
                               fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.processSpawn, fileID: fileID, line: line) { posix_spawn(pid, path, fileActions, attributes, argv, envp) }
}
