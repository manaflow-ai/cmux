public import Foundation
public import IrohLib

/// Iroh's QUIC connection; the TLS handshake authenticates `remoteId()`.
public struct IrohCarrierConnection: IrxCarrierConnection {
    /// The underlying Iroh connection every call forwards to.
    public let connection: Connection
    /// Lowercase hex Ed25519 EndpointID Iroh's TLS handshake proved.
    public let remoteEndpointIDHex: String

    /// Wraps an already-established Iroh connection.
    public init(_ connection: Connection) {
        self.connection = connection
        remoteEndpointIDHex = connection.remoteId().toBytes()
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Iroh's own stable connection identifier.
    public var stableID: UInt64 { connection.stableId() }

    /// Opens an outbound bidirectional stream on the Iroh connection.
    public func openBi() async throws -> (send: any IrxCarrierSendStream, recv: any IrxCarrierRecvStream) {
        let stream = try await connection.openBi()
        return (IrohCarrierSendStream(stream: stream.send()), IrohCarrierRecvStream(stream: stream.recv()))
    }

    /// Opens an outbound send-only stream on the Iroh connection.
    public func openUni() async throws -> any IrxCarrierSendStream {
        IrohCarrierSendStream(stream: try await connection.openUni())
    }

    /// Waits for the peer to open a bidirectional stream.
    public func acceptBi() async throws -> (send: any IrxCarrierSendStream, recv: any IrxCarrierRecvStream) {
        let stream = try await connection.acceptBi()
        return (IrohCarrierSendStream(stream: stream.send()), IrohCarrierRecvStream(stream: stream.recv()))
    }

    /// Waits for the peer to open a send-only stream, yielding its receive half.
    public func acceptUni() async throws -> any IrxCarrierRecvStream {
        IrohCarrierRecvStream(stream: try await connection.acceptUni())
    }

    /// The rendered close cause Iroh already published, without waiting.
    public func closeReason() -> String? { connection.closeReason() }
    /// Waits for the connection to end and returns Iroh's rendered cause.
    public func closed() async -> String { await connection.closed() }

    /// Closes the connection, carrying `reason` to the peer; close errors are ignored.
    public func close(errorCode: UInt64, reason: Data) {
        try? connection.close(errorCode: Int64(clamping: errorCode), reason: reason)
    }

    /// Raises the concurrent stream budgets granted to the peer.
    public func setMaxConcurrentStreams(bi: UInt64, uni: UInt64) {
        try? connection.setMaxConcurrentBiStreams(count: bi)
        try? connection.setMaxConcurrentUniStreams(count: uni)
    }

    /// Authorizes Iroh's NAT traversal for this connection.
    public func authorizeNatTraversal() async throws {
        try await connection.authorizeNatTraversal()
    }

    /// Attributes the selected Iroh path, falling back to the first known path.
    public func selectedPath() -> (kind: IrxCarrierPathKind, description: String) {
        let paths = connection.paths()
        guard let selected = paths.first(where: { $0.isSelected }) ?? paths.first else {
            return (.unknown, "none")
        }
        return (selected.isRelay ? .relay : .direct,
                "\(selected.isRelay ? "relay" : "direct"):\(selected.remoteAddr)")
    }
}
