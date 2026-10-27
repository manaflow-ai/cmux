#if canImport(ServiceManagement)
public import ServiceManagement

/// The service's registration state, like `SMAppService.status`, as a checked blocking call
/// (``blockingCall(_:fileID:line:_:)``): it sends a message to backgroundtaskmanagementd and waits
/// for the reply. Read it off the main thread.
///
/// - Parameters:
///   - service: The service.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The state.
@inlinable
public func blockingSMAppServiceStatus(_ service: SMAppService, fileID: StaticString = #fileID, line: UInt = #line) -> SMAppService.Status {
    return blockingCall(.ipcReply, fileID: fileID, line: line) { service.status }
}

/// Registers the service, like `SMAppService.register()`, as a checked blocking call: it waits for
/// backgroundtaskmanagementd's reply.
///
/// - Parameters:
///   - service: The service.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Throws: What `register()` throws.
@inlinable
public func blockingSMAppServiceRegister(_ service: SMAppService, fileID: StaticString = #fileID, line: UInt = #line) throws {
    try blockingCall(.ipcReply, fileID: fileID, line: line) { try service.register() }
}

/// Unregisters the service, like `SMAppService.unregister()`, as a checked blocking call: it waits for
/// backgroundtaskmanagementd's reply.
///
/// - Parameters:
///   - service: The service.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Throws: What `unregister()` throws.
@inlinable
public func blockingSMAppServiceUnregister(_ service: SMAppService, fileID: StaticString = #fileID, line: UInt = #line) throws {
    try blockingCall(.ipcReply, fileID: fileID, line: line) { try service.unregister() }
}
#endif
