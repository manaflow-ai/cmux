public import Foundation
public import IrohLib

/// Send half of one carrier stream.
public protocol IrxCarrierSendStream: Sendable {
    func writeAll(_ data: Data) async throws
    func finish() async throws
    func reset(errorCode: UInt64) async throws
    func setPriority(_ priority: Int32) async throws
}

/// Receive half of one carrier stream.
public protocol IrxCarrierRecvStream: Sendable {
    /// Up to `sizeLimit` bytes; an empty result means the peer finished.
    func read(sizeLimit: UInt32) async throws -> Data
    func stop(errorCode: UInt64) async throws
}

/// The attributed kind of the path currently carrying a connection.
public enum IrxCarrierPathKind: Sendable, Equatable {
    case direct
    case relay
    case unknown
}

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

    func openBi() async throws -> (send: any IrxCarrierSendStream, recv: any IrxCarrierRecvStream)
    func openUni() async throws -> any IrxCarrierSendStream
    func acceptBi() async throws -> (send: any IrxCarrierSendStream, recv: any IrxCarrierRecvStream)
    func acceptUni() async throws -> any IrxCarrierRecvStream

    /// The rendered close cause already published, without waiting.
    func closeReason() -> String?
    /// Waits for the connection to end and returns the rendered cause.
    func closed() async -> String
    /// Closes the connection, carrying `reason` to the peer.
    func close(errorCode: UInt64, reason: Data)

    func setMaxConcurrentStreams(bi: UInt64, uni: UInt64)
    /// Allows NAT traversal on carriers that relay; a no-op elsewhere.
    func authorizeNatTraversal() async throws
    func selectedPath() -> (kind: IrxCarrierPathKind, description: String)
}

// MARK: - Iroh carrier

struct IrohCarrierSendStream: IrxCarrierSendStream {
    let stream: SendStream

    func writeAll(_ data: Data) async throws { try await stream.writeAll(buf: data) }
    func finish() async throws { try await stream.finish() }
    func reset(errorCode: UInt64) async throws { try await stream.reset(errorCode: errorCode) }
    func setPriority(_ priority: Int32) async throws { try await stream.setPriority(p: priority) }
}

struct IrohCarrierRecvStream: IrxCarrierRecvStream {
    let stream: RecvStream

    func read(sizeLimit: UInt32) async throws -> Data { try await stream.read(sizeLimit: sizeLimit) }
    func stop(errorCode: UInt64) async throws { try await stream.stop(errorCode: errorCode) }
}

/// Iroh's QUIC connection; the TLS handshake authenticates `remoteId()`.
public struct IrohCarrierConnection: IrxCarrierConnection {
    public let connection: Connection
    public let remoteEndpointIDHex: String

    public init(_ connection: Connection) {
        self.connection = connection
        remoteEndpointIDHex = connection.remoteId().toBytes()
            .map { String(format: "%02x", $0) }.joined()
    }

    public var stableID: UInt64 { connection.stableId() }

    public func openBi() async throws -> (send: any IrxCarrierSendStream, recv: any IrxCarrierRecvStream) {
        let stream = try await connection.openBi()
        return (IrohCarrierSendStream(stream: stream.send()), IrohCarrierRecvStream(stream: stream.recv()))
    }

    public func openUni() async throws -> any IrxCarrierSendStream {
        IrohCarrierSendStream(stream: try await connection.openUni())
    }

    public func acceptBi() async throws -> (send: any IrxCarrierSendStream, recv: any IrxCarrierRecvStream) {
        let stream = try await connection.acceptBi()
        return (IrohCarrierSendStream(stream: stream.send()), IrohCarrierRecvStream(stream: stream.recv()))
    }

    public func acceptUni() async throws -> any IrxCarrierRecvStream {
        IrohCarrierRecvStream(stream: try await connection.acceptUni())
    }

    public func closeReason() -> String? { connection.closeReason() }
    public func closed() async -> String { await connection.closed() }

    public func close(errorCode: UInt64, reason: Data) {
        try? connection.close(errorCode: Int64(clamping: errorCode), reason: reason)
    }

    public func setMaxConcurrentStreams(bi: UInt64, uni: UInt64) {
        try? connection.setMaxConcurrentBiStreams(count: bi)
        try? connection.setMaxConcurrentUniStreams(count: uni)
    }

    public func authorizeNatTraversal() async throws {
        try await connection.authorizeNatTraversal()
    }

    public func selectedPath() -> (kind: IrxCarrierPathKind, description: String) {
        let paths = connection.paths()
        guard let selected = paths.first(where: { $0.isSelected }) ?? paths.first else {
            return (.unknown, "none")
        }
        return (selected.isRelay ? .relay : .direct,
                "\(selected.isRelay ? "relay" : "direct"):\(selected.remoteAddr)")
    }
}
