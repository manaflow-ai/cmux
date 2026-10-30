public import Darwin

/// ``blockingPosixSpawn(_:_:_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingPosixSpawn(_ pid: UnsafeMutablePointer<pid_t>?, _ path: UnsafePointer<CChar>,
                               _ fileActions: UnsafePointer<posix_spawn_file_actions_t?>?,
                               _ attributes: UnsafePointer<posix_spawnattr_t?>?,
                               _ argv: UnsafePointer<UnsafeMutablePointer<CChar>?>,
                               _ envp: UnsafePointer<UnsafeMutablePointer<CChar>?>?,
                               _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to posix_spawn unchanged, only for the call; the caller's own `unsafe`
    // states why they are valid for it.
    return blockingCall(.processSpawn, permit, fileID: fileID, line: line) { unsafe posix_spawn(pid, path, fileActions, attributes, argv, envp) }
}

/// ``blockingPosixSpawn(_:_:_:_:_:_:priority:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingPosixSpawn(_ pid: UnsafeMutablePointer<pid_t>?, _ path: UnsafePointer<CChar>,
                               _ fileActions: UnsafePointer<posix_spawn_file_actions_t?>?,
                               _ attributes: UnsafeMutablePointer<posix_spawnattr_t?>?,
                               _ argv: UnsafePointer<UnsafeMutablePointer<CChar>?>,
                               _ envp: UnsafePointer<UnsafeMutablePointer<CChar>?>?,
                               priority: MayBlockPriority,
                               _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    guard let attributes = unsafe attributes else {
        var own: posix_spawnattr_t?
        // SAFETY: `own` is a local attributes object, initialized here and destroyed once by the defer, after the
        // spawn below; the caller's pointers go on unchanged.
        let initialized = unsafe posix_spawnattr_init(&own)
        guard initialized == 0 else { return initialized }
        defer { unsafe posix_spawnattr_destroy(&own) }
        return unsafe blockingPosixSpawn(pid, path, fileActions, &own, argv, envp, priority: priority, permit, fileID: fileID, line: line)
    }
    if let ceiling = priority.spawnClamp {
        // SAFETY: `attributes` is the caller's initialized attributes object, lent for this call.
        let clamped = unsafe posix_spawnattr_set_qos_class_np(attributes, ceiling)
        guard clamped == 0 else { return clamped }
    }
    // No signal blocked and every signal at its default action in the child (the form without a permit says why).
    let signals = unsafe spawnWithDefaultSignals(attributes)
    guard signals == 0 else { return signals }
    // SAFETY: forwards the caller's pointers to posix_spawn unchanged, only for the call; the caller's own `unsafe`
    // states why they are valid for it.
    return blockingCall(.processSpawn, permit, fileID: fileID, line: line) { unsafe posix_spawn(pid, path, fileActions, attributes, argv, envp) }
}
