public import Foundation

/// One authenticated QUIC connection underneath the irx session protocol.
///
/// irx owns admission, lanes, keepalive, and attributed closes. A carrier
/// owns only the QUIC connection and the peer key it authenticated, so the
/// same session protocol runs over Iroh (`IrohCarrierConnection`) or over
/// Network.framework QUIC to an exact host and port
/// (`DirectQuicCarrierConnection`).
public protocol IrxCarrierConnection: Sendable {
    /// Lowercase hex Ed25519 public key the carrier authenticated.
    var remoteEndpointIDHex: String { get }
    /// Stable identity of this QUIC connection for continuity checks.
    var stableID: UInt64 { get }

    /// Opens an outbound bidirectional stream.
    func openBi() async throws -> (send: any IrxCarrierSendStream, recv: any IrxCarrierRecvStream)
    /// Opens an outbound send-only stream.
    func openUni() async throws -> any IrxCarrierSendStream
    /// Waits for the peer to open a bidirectional stream.
    func acceptBi() async throws -> (send: any IrxCarrierSendStream, recv: any IrxCarrierRecvStream)
    /// Waits for the peer to open a send-only stream, yielding its receive half.
    func acceptUni() async throws -> any IrxCarrierRecvStream

    /// The rendered close cause already published, without waiting.
    func closeReason() -> String?
    /// Waits for the connection to end and returns the rendered cause.
    func closed() async -> String
    /// Closes the connection, carrying `reason` to the peer.
    func close(errorCode: UInt64, reason: Data)

    /// Raises the concurrent stream budgets granted to the peer.
    func setMaxConcurrentStreams(bi: UInt64, uni: UInt64)
    /// Allows NAT traversal on carriers that relay; a no-op elsewhere.
    func authorizeNatTraversal() async throws
    /// The attributed kind and rendered description of the current path.
    func selectedPath() -> (kind: IrxCarrierPathKind, description: String)
}
