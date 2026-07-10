public import CMUXMobileCore

/// An authenticated Iroh QUIC connection capable of independent app streams.
public protocol CmxIrohConnection: Sendable {
    /// Returns the peer EndpointID authenticated by QUIC TLS.
    func remoteIdentity() async -> CmxIrohPeerIdentity

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

    /// Closes the complete connection and all child streams.
    ///
    /// - Parameters:
    ///   - errorCode: The application close code.
    ///   - reason: A bounded non-sensitive reason for local diagnostics.
    func close(errorCode: UInt64, reason: String) async
}
