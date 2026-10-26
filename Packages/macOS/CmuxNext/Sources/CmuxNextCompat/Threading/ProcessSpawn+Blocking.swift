public import Darwin

/// Spawns a process, like `posix_spawn`, as a checked blocking call
/// (``blockingCall(_:fileID:line:_:)``): a spawn on the main thread stalls it. Spawn from an actor
/// or a `@concurrent` function. App code states the child's QoS with
/// ``blockingPosixSpawn(_:_:_:_:_:_:qos:fileID:line:)``; this form leaves it to the spawning thread.
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
@inlinable
public func blockingPosixSpawn(_ pid: UnsafeMutablePointer<pid_t>?, _ path: UnsafePointer<CChar>,
                               _ fileActions: UnsafePointer<posix_spawn_file_actions_t?>?,
                               _ attributes: UnsafePointer<posix_spawnattr_t?>?,
                               _ argv: UnsafePointer<UnsafeMutablePointer<CChar>?>,
                               _ envp: UnsafePointer<UnsafeMutablePointer<CChar>?>?,
                               fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.processSpawn, fileID: fileID, line: line) { posix_spawn(pid, path, fileActions, attributes, argv, envp) }
}

/// Spawns a process at `qos`, like `posix_spawn`, as a checked blocking call
/// (``blockingCall(_:fileID:line:_:)``). Call it inside ``ChildSpawnQueue/run(_:)`` with the queue's QoS:
/// the queue's thread runs at `qos`, which the child takes, and for ``ChildProcessQoS/utility`` and
/// ``ChildProcessQoS/background`` this seam also sets `posix_spawnattr_set_qos_class_np`, a ceiling the
/// child and its descendants keep.
///
/// - Parameters:
///   - pid: Receives the child's process id.
///   - path: The executable.
///   - fileActions: `posix_spawn` file actions.
///   - attributes: `posix_spawn` attributes, which receive the QoS ceiling; nil spawns with attributes of
///     the seam's own that carry only the ceiling.
///   - argv: The arguments, ending with nil.
///   - envp: The environment, ending with nil.
///   - qos: The child's QoS.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `posix_spawn` returns (0, or an error number), or the error number of the attributes'
///   setup; the child is not started then.
@inlinable
public func blockingPosixSpawn(_ pid: UnsafeMutablePointer<pid_t>?, _ path: UnsafePointer<CChar>,
                               _ fileActions: UnsafePointer<posix_spawn_file_actions_t?>?,
                               _ attributes: UnsafeMutablePointer<posix_spawnattr_t?>?,
                               _ argv: UnsafePointer<UnsafeMutablePointer<CChar>?>,
                               _ envp: UnsafePointer<UnsafeMutablePointer<CChar>?>?,
                               qos: ChildProcessQoS,
                               fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    guard let attributes else {
        var own: posix_spawnattr_t?
        let initialized = posix_spawnattr_init(&own)
        guard initialized == 0 else { return initialized }
        defer { posix_spawnattr_destroy(&own) }
        return blockingPosixSpawn(pid, path, fileActions, &own, argv, envp, qos: qos, fileID: fileID, line: line)
    }
    if let ceiling = qos.spawnClamp {
        let clamped = posix_spawnattr_set_qos_class_np(attributes, ceiling)
        guard clamped == 0 else { return clamped }
    }
    return blockingCall(.processSpawn, fileID: fileID, line: line) { posix_spawn(pid, path, fileActions, attributes, argv, envp) }
}
