public import CMUXMobileCore

/// One authenticated iOS peer connection exposed to the Mac application layer.
///
/// The control transport preserves the existing mobile RPC protocol while the
/// lane methods expose independent terminal, event, and artifact streams on the
/// same admitted QUIC connection. Only ``CmxIrohHostRuntime`` constructs this
/// value, after binding the admission credential to the live TLS EndpointID.
public struct CmxIrohAdmittedServerSession: Sendable {
    /// The exact iOS binding authenticated for this connection.
    public let peer: CmxIrohAdmittedPeer

    /// The existing mobile RPC byte stream on the connection's control lane.
    public let controlTransport: any CmxByteTransport

    private let session: CmxIrohServerSession

    init(
        peer: CmxIrohAdmittedPeer,
        session: CmxIrohServerSession
    ) {
        self.peer = peer
        self.session = session
        controlTransport = CmxIrohServerByteTransport(session: session)
    }

    /// Accepts one client-created terminal or artifact lane.
    public func acceptBidirectionalLane() async throws -> (
        lane: CmxIrohLane,
        stream: CmxIrohBidirectionalStream
    ) {
        try await session.acceptBidirectionalLane()
    }

    /// Opens one server-event or artifact lane to the admitted iOS peer.
    public func openSendLane(
        _ lane: CmxIrohLane,
        priority: Int32
    ) async throws -> any CmxIrohSendStream {
        try await session.openSendLane(lane, priority: priority)
    }

    /// Closes the complete peer connection and every child stream.
    public func close() async {
        await session.close()
    }

    /// Resolves an observed supervisor exit against a named host-side close cause.
    ///
    /// - Parameter observedExit: The first control or application-lane exit.
    /// - Returns: The host invalidation exit when one initiated the close;
    ///   otherwise, `observedExit`.
    public func connectionExit(
        resolving observedExit: CmxIrohAdmittedConnectionExit
    ) async -> CmxIrohAdmittedConnectionExit {
        guard let failure = await session.explicitCloseFailureKind() else {
            return observedExit
        }
        return CmxIrohAdmittedConnectionExit(
            lifecycle: .explicitlyInvalidated,
            failure: failure
        )
    }

    /// Returns the classified terminal cause for the shared QUIC connection.
    public func closeAttribution() async -> CmxIrohConnectionCloseAttribution {
        await session.closeAttribution()
    }

    /// Observes redacted lifecycle events for paths on the shared connection.
    public func observedPathEvents() async -> AsyncStream<CmxIrohConnectionPathEvent> {
        await session.observedPathEvents()
    }
}
