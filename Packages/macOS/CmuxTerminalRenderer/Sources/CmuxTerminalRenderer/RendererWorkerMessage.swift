internal import XPC

/// One host message accepted by a renderer worker listener.
public struct RendererWorkerMessage: @unchecked Sendable {
    public let message: RendererXPCObject
    private let reply: @Sendable (RendererXPCObject) -> Void

    init(message: xpc_object_t, peer: xpc_object_t) {
        self.message = RendererXPCObject(message)
        let peer = RendererXPCObject(peer)
        reply = { event in xpc_connection_send_message(peer.value, event.value) }
    }

    init(message: xpc_object_t, peer: RendererXPCObject) {
        self.message = RendererXPCObject(message)
        reply = { event in xpc_connection_send_message(peer.value, event.value) }
    }

    public init(
        message: RendererXPCObject,
        reply: @escaping @Sendable (RendererXPCObject) -> Void
    ) {
        self.message = message
        self.reply = reply
    }

    /// Sends an event to the connected cmux host.
    public func send(_ event: RendererXPCObject) {
        reply(event)
    }
}
