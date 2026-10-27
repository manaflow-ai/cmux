public import ServiceManagement

/// ``blockingSMAppServiceStatus(_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingSMAppServiceStatus(_ service: SMAppService, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> SMAppService.Status {
    return blockingCall(.ipcReply, permit, fileID: fileID, line: line) { service.status }
}

/// ``blockingSMAppServiceRegister(_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingSMAppServiceRegister(_ service: SMAppService, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws {
    try blockingCall(.ipcReply, permit, fileID: fileID, line: line) { try service.register() }
}

/// ``blockingSMAppServiceUnregister(_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingSMAppServiceUnregister(_ service: SMAppService, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws {
    try blockingCall(.ipcReply, permit, fileID: fileID, line: line) { try service.unregister() }
}
