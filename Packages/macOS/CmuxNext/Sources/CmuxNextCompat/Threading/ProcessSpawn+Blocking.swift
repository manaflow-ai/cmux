public import Darwin

/// Spawns a process, like `posix_spawn`, as a checked blocking call
/// (``blockingCall(_:fileID:line:_:)``): a spawn on the main thread stalls it. Spawn from an actor
/// or a `@concurrent` function. App code spawns through ``ChildProcessLauncher`` and the
/// ``blockingPosixSpawn(_:_:_:_:_:_:priority:fileID:line:)`` form, which states the child's priority.
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
    // SAFETY: forwards the caller's pointers to posix_spawn unchanged, only for the call; the caller's own `unsafe`
    // states why they are valid for it.
    return blockingCall(.processSpawn, fileID: fileID, line: line) { unsafe posix_spawn(pid, path, fileActions, attributes, argv, envp) }
}

/// Spawns a process, like `posix_spawn`, as a checked blocking call (``blockingCall(_:fileID:line:_:)``),
/// clamped to `priority` when that is ``MayBlockPriority/bestEffort`` or ``MayBlockPriority/idle``. Call it
/// inside ``ChildProcessLauncher/run(_:)`` with the launcher's priority.
///
/// The clamp is `posix_spawnattr_set_qos_class_np` (``MayBlockPriority/spawnClamp``): a QoS ceiling the child
/// and its descendants keep. For ``MayBlockPriority/userVisible`` and ``MayBlockPriority/userBlocking`` the
/// seam sets nothing on the child. Darwin does not document that a child takes the spawning thread's QoS, so
/// nothing here relies on it (ChildProcessLauncherTests compare what a child reports when it is spawned from a
/// launcher and from the main thread).
///
/// - Parameters:
///   - pid: Receives the child's process id.
///   - path: The executable.
///   - fileActions: `posix_spawn` file actions.
///   - attributes: `posix_spawn` attributes, which receive the clamp; nil spawns with attributes of the
///     seam's own that carry only the clamp.
///   - argv: The arguments, ending with nil.
///   - envp: The environment, ending with nil.
///   - priority: How much a person waits for the child.
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
                               priority: MayBlockPriority,
                               fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    guard let attributes = unsafe attributes else {
        var own: posix_spawnattr_t?
        // SAFETY: `own` is a local attributes object, initialized here and destroyed once by the defer, after the
        // spawn below; the caller's pointers go on unchanged.
        let initialized = unsafe posix_spawnattr_init(&own)
        guard initialized == 0 else { return initialized }
        defer { unsafe posix_spawnattr_destroy(&own) }
        return unsafe blockingPosixSpawn(pid, path, fileActions, &own, argv, envp, priority: priority, fileID: fileID, line: line)
    }
    if let ceiling = priority.spawnClamp {
        // SAFETY: `attributes` is the caller's initialized attributes object, lent for this call.
        let clamped = unsafe posix_spawnattr_set_qos_class_np(attributes, ceiling)
        guard clamped == 0 else { return clamped }
    }
    // SAFETY: forwards the caller's pointers to posix_spawn unchanged, only for the call; the caller's own `unsafe`
    // states why they are valid for it.
    return blockingCall(.processSpawn, fileID: fileID, line: line) { unsafe posix_spawn(pid, path, fileActions, attributes, argv, envp) }
}

extension MayBlockPriority {
    /// The QoS ceiling ``blockingPosixSpawn(_:_:_:_:_:_:priority:fileID:line:)`` sets on a child of this
    /// priority: utility for ``bestEffort``, background for ``idle``, nil above. `posix_spawnattr_set_qos_class_np`
    /// accepts only utility, background and maintenance (libpthread's qos.c maps them to a task QoS clamp and
    /// refuses the rest with `EINVAL`).
    public var spawnClamp: qos_class_t? {
        switch self {
        case .userBlocking, .userVisible: nil
        case .bestEffort: QOS_CLASS_UTILITY
        case .idle: QOS_CLASS_BACKGROUND
        }
    }
}
