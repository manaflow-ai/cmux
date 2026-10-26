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
    return blockingCall(.processSpawn, permit, fileID: fileID, line: line) { posix_spawn(pid, path, fileActions, attributes, argv, envp) }
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
    guard let attributes else {
        var own: posix_spawnattr_t?
        let initialized = posix_spawnattr_init(&own)
        guard initialized == 0 else { return initialized }
        defer { posix_spawnattr_destroy(&own) }
        return blockingPosixSpawn(pid, path, fileActions, &own, argv, envp, priority: priority, permit, fileID: fileID, line: line)
    }
    if let ceiling = priority.spawnClamp {
        let clamped = posix_spawnattr_set_qos_class_np(attributes, ceiling)
        guard clamped == 0 else { return clamped }
    }
    return blockingCall(.processSpawn, permit, fileID: fileID, line: line) { posix_spawn(pid, path, fileActions, attributes, argv, envp) }
}
