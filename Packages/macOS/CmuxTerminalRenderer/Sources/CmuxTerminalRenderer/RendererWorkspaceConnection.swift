public import Foundation

/// Direct asynchronous pipe connection to one workspace renderer process.
public actor RendererWorkspaceConnection {
    public nonisolated let events: AsyncStream<RendererXPCObject>

    private nonisolated let transport: RendererPipeTransport

    public init(
        reading input: FileHandle,
        writing output: FileHandle,
        surfacePortReceiver: RendererSurfacePortReceiver
    ) {
        transport = RendererPipeTransport(
            reading: input,
            writing: output,
            bufferingPolicy: .bufferingNewest(256),
            surfacePortReceiver: surfacePortReceiver
        )
        events = transport.messages
    }

    deinit {
        transport.close()
    }

    /// Sends an immutable message to the workspace worker.
    public func send(_ message: RendererXPCObject) {
        transport.send(message)
    }

    /// Queues a serialized producer's message without hopping through the
    /// actor. Encoding is synchronous; pipe writes drain on a dedicated queue.
    public nonisolated func sendImmediately(_ message: RendererXPCObject) {
        transport.send(message)
    }

    public func cancel() {
        transport.close()
    }
}
