public import ServiceManagement

// Checked seams over SMAppService: each call is a synchronous message to backgroundtaskmanagementd that
// waits for its reply (``assertBlockingAllowed(_:fileID:line:)``). Each forwards its caller's `fileID`
// and `line`; call them off the main thread.
extension SMAppService {
    /// The service's registration state, like `status`, as a checked blocking call.
    ///
    /// - Returns: The state.
    @inlinable
    public func blockingStatus(fileID: StaticString = #fileID, line: UInt = #line) -> SMAppService.Status {
        assertBlockingAllowed(.ipcReply, fileID: fileID, line: line)
        return status
    }

    /// Registers the service, like `register()`, as a checked blocking call.
    ///
    /// - Throws: What `register()` throws.
    @inlinable
    public func blockingRegister(fileID: StaticString = #fileID, line: UInt = #line) throws {
        assertBlockingAllowed(.ipcReply, fileID: fileID, line: line)
        try register()
    }

    /// Unregisters the service, like `unregister()`, as a checked blocking call.
    ///
    /// - Throws: What `unregister()` throws.
    @inlinable
    public func blockingUnregister(fileID: StaticString = #fileID, line: UInt = #line) throws {
        assertBlockingAllowed(.ipcReply, fileID: fileID, line: line)
        try unregister()
    }
}
