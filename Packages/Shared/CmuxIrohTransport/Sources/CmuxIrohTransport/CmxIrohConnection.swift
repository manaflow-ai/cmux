public import CMUXMobileCore

/// An authenticated Iroh QUIC connection capable of independent app streams.
public protocol CmxIrohConnection: Sendable {
    /// Returns the peer EndpointID authenticated by QUIC TLS.
    func remoteIdentity() async -> CmxIrohPeerIdentity

    /// Bounds streams initiated by the peer before application code accepts them.
    ///
    /// A zero limit disables that stream direction. The limit applies to
    /// concurrent streams and QUIC releases capacity when a stream closes.
    func setIncomingStreamLimits(
        maximumBidirectionalStreamCount: UInt64,
        maximumUnidirectionalStreamCount: UInt64
    ) async throws

    /// Irreversibly enables NAT-traversal candidate exchange on this connection.
    ///
    /// Calls are idempotent. Admission code invokes this only after authenticating
    /// the peer and keeps application lanes unavailable until both peers confirm it.
    func authorizeNatTraversal() async throws

    /// Opens a new bidirectional application stream.
    ///
    /// - Returns: Independent receive and send halves.
    /// - Throws: A transport error or `CancellationError`.
    func openBidirectionalStream() async throws -> CmxIrohBidirectionalStream

    /// Accepts the next peer-created bidirectional stream.
    ///
    /// - Returns: Independent receive and send halves.
    /// - Throws: A transport error or `CancellationError`.
    func acceptBidirectionalStream() async throws -> CmxIrohBidirectionalStream

    /// Opens a new unidirectional send stream.
    ///
    /// - Returns: The writable stream half.
    /// - Throws: A transport error or `CancellationError`.
    func openSendStream() async throws -> any CmxIrohSendStream

    /// Accepts the next peer-created unidirectional receive stream.
    ///
    /// - Returns: The readable stream half.
    /// - Throws: A transport error or `CancellationError`.
    func acceptReceiveStream() async throws -> any CmxIrohReceiveStream

    /// Suspends until this exact QUIC connection has closed.
    ///
    /// Session-scoped policy monitors use this signal to retain revocation
    /// enforcement for the complete connection lifetime.
    func waitUntilClosed() async

    /// Returns whether this connection already has a terminal close reason.
    ///
    /// Callers use this nonblocking snapshot to reject a cached connection
    /// before its asynchronous closure watcher has been scheduled.
    func isClosed() async -> Bool

    /// Closes the complete connection and all child streams.
    ///
    /// - Parameters:
    ///   - errorCode: The application close code.
    ///   - reason: A bounded non-sensitive reason for local diagnostics.
    func close(errorCode: UInt64, reason: String) async
}
