public import XPC

/// ``blockingXPCSendWithReply(_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingXPCSendWithReply(_ connection: xpc_connection_t, _ message: xpc_object_t,
                                     _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> xpc_object_t {
    return blockingCall(.xpcReply, permit, fileID: fileID, line: line) { xpc_connection_send_message_with_reply_sync(connection, message) }
}
