public import Foundation

/// The send half of one QUIC stream, as ``IrxStreamWriter`` uses it.
public protocol IrxQUICSendStream: Sendable {
    func writeAll(_ data: Data) async throws
    func setPriority(_ priority: Int32) async throws
    func finish() async throws
    func reset(errorCode: UInt64) async throws
}

/// The receive half of one QUIC stream, as ``IrxStreamReader`` uses it.
public protocol IrxQUICRecvStream: Sendable {
    /// Up to `sizeLimit` bytes; empty at end of stream.
    func read(sizeLimit: UInt32) async throws -> Data
    func stop(errorCode: UInt64) async throws
}

/// One bidirectional QUIC stream.
public struct IrxQUICBiStream: Sendable {
    public let send: any IrxQUICSendStream
    public let recv: any IrxQUICRecvStream

    public init(send: any IrxQUICSendStream, recv: any IrxQUICRecvStream) {
        self.send = send
        self.recv = recv
    }
}

/// One network path of a QUIC connection.
public struct IrxQUICPath: Equatable, Sendable {
    public var isSelected: Bool
    public var isRelay: Bool
    /// The relay URL for a relayed path, the socket address otherwise.
    public var remoteAddress: String

    public init(isSelected: Bool, isRelay: Bool, remoteAddress: String) {
        self.isSelected = isSelected
        self.isRelay = isRelay
        self.remoteAddress = remoteAddress
    }
}

/// The QUIC connection ``IrxConnection`` drives. The iroh adapter is the production one; the
/// session, admission and keepalive logic above it depends only on this.
public protocol IrxQUICConnection: Sendable {
    /// The peer's endpoint ID (its Ed25519 public key).
    func remoteEndpointID() -> Data
    /// Stable identity of this QUIC connection across path changes.
    func stableID() -> UInt64
    func paths() -> [IrxQUICPath]
    /// The close reason once the connection has closed, without waiting.
    func closeReason() -> String?
    /// Resolves when the connection has closed, with the rendered cause.
    func closed() async -> String
    func setMaxConcurrentBiStreams(_ count: UInt64) throws
    func setMaxConcurrentUniStreams(_ count: UInt64) throws
    func openBi() async throws -> IrxQUICBiStream
    func openUni() async throws -> any IrxQUICSendStream
    func acceptBi() async throws -> IrxQUICBiStream
    func acceptUni() async throws -> any IrxQUICRecvStream
    func authorizeNatTraversal() async throws
    func close(errorCode: Int64, reason: Data) throws
}
