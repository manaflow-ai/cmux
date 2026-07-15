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
}
