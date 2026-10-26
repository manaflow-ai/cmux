public import XPC

/// Sends an XPC message and waits for its reply, like `xpc_connection_send_message_with_reply_sync`,
/// as a checked blocking call (``blockingCall(_:fileID:line:_:)``): the caller waits for
/// another process. Use `xpc_connection_send_message_with_reply` with a reply queue instead.
///
/// - Parameters:
///   - connection: The connection.
///   - message: The message.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The reply.
@inlinable
public func blockingXPCSendWithReply(_ connection: xpc_connection_t, _ message: xpc_object_t,
                                     fileID: StaticString = #fileID, line: UInt = #line) -> xpc_object_t {
    return blockingCall(.ipcReply, fileID: fileID, line: line) { xpc_connection_send_message_with_reply_sync(connection, message) }
}
