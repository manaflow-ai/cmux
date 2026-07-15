public import CMUXMobileCore
public import Foundation

/// Adapts an admitted Iroh control stream to the existing mobile RPC byte seam.
public actor CmxIrohByteTransport: CmxByteTransport {
    private let request: CmxByteTransportRequest
    private let supervisor: CmxIrohEndpointSupervisor
    private let contextProvider: any CmxIrohClientContextProvider
    private var connectTask: Task<CmxIrohClientSession, any Error>?
    private var session: CmxIrohClientSession?
    private var closed = false

    /// Creates a disconnected byte transport.
    ///
    /// - Parameters:
    ///   - request: The validated Iroh peer route and intended Mac binding.
    ///   - supervisor: The active endpoint owner.
    ///   - contextProvider: The fresh dial-plan and grant provider.
    public init(
        request: CmxByteTransportRequest,
        supervisor: CmxIrohEndpointSupervisor,
        contextProvider: any CmxIrohClientContextProvider
    ) {
        self.request = request
        self.supervisor = supervisor
        self.contextProvider = contextProvider
    }

    /// Resolves current trust and reachability, then admits the control stream.
    ///
    /// Concurrent callers share one cancellable dial operation.
    ///
    /// - Throws: A route, registry, endpoint, transport, or cancellation error.
    public func connect() async throws {
        guard !closed else { throw CmxIrohByteTransportError.alreadyClosed }
        if session != nil { return }
        guard case let .peer(identity, _) = request.route.endpoint else {
            throw CmxIrohByteTransportError.unsupportedEndpoint(request.route.endpoint)
        }

        let task: Task<CmxIrohClientSession, any Error>
        if let connectTask {
            task = connectTask
        } else {
            let supervisor = supervisor
            let contextProvider = contextProvider
            let request = request
            task = Task {
                let endpoint = try await supervisor.activeEndpoint()
                let context = try await contextProvider.context(for: request)
                let session = try CmxIrohClientSession(
                    endpoint: endpoint,
                    targetIdentity: identity,
                    dialPlan: context.dialPlan,
                    credential: context.credential,
                    privateFallbackAuthorization: context.privateFallbackAuthorization,
                    privateFallbackValidator: contextProvider
                )
                do {
                    try await session.connect()
                    try Task.checkCancellation()
                    return session
                } catch {
                    await session.close()
                    throw error
                }
            }
            connectTask = task
        }

        do {
            let connected = try await withTaskCancellationHandler(operation: {
                try await task.value
            }, onCancel: {
                task.cancel()
            })
            if closed {
                await connected.close()
                throw CmxIrohByteTransportError.alreadyClosed
            }
            session = connected
            connectTask = nil
        } catch {
            connectTask = nil
            throw error
        }
    }

    /// Receives the next admitted control-lane bytes.
    ///
    /// - Returns: Application bytes, or `nil` after a clean peer finish.
    /// - Throws: A transport or lifecycle error.
    public func receive() async throws -> Data? {
        guard !closed else { throw CmxIrohByteTransportError.alreadyClosed }
        guard let session else { throw CmxIrohByteTransportError.notConnected }
        return try await session.receiveControl()
    }

    /// Sends a complete application buffer on the admitted control lane.
    ///
    /// - Parameter data: The RPC framing bytes to send.
    /// - Throws: A transport or lifecycle error.
    public func send(_ data: Data) async throws {
        guard !closed else { throw CmxIrohByteTransportError.alreadyClosed }
        guard let session else { throw CmxIrohByteTransportError.notConnected }
        try await session.sendControl(data)
    }

    /// Cancels any dial and closes the Iroh connection.
    public func close() async {
        guard !closed else { return }
        closed = true
        connectTask?.cancel()
        connectTask = nil
        let closingSession = session
        session = nil
        await closingSession?.close()
    }
}
