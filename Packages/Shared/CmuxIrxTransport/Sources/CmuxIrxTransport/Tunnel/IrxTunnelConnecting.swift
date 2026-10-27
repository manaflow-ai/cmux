public import Foundation

/// One outbound TCP connection the tunnel relays to. Every call suspends
/// until the operation is done, which is what bounds the relay's memory:
/// a relay never reads its next chunk before the previous one was sent.
public protocol IrxTunnelByteChannel: Sendable {
    /// The next chunk, or nil once the remote end finished sending.
    func receive(maximumByteCount: Int) async throws -> Data?
    func send(_ data: Data) async throws
    /// Half-close: no more bytes from us (TCP FIN).
    func finishSending() async
    /// Abort both directions.
    func cancel()
}

/// Opens outbound TCP connections from this Mac.
public protocol IrxTunnelConnecting: Sendable {
    /// Resolves a host name to addresses (no policy applied here).
    func resolve(host: String) async -> [IrxTunnelIPAddress]
    /// Connects to the first address that accepts, trying them in order.
    func connect(
        to addresses: [IrxTunnelIPAddress],
        port: Int,
        timeout: Duration
    ) async throws(IrxTunnelOpenError) -> any IrxTunnelByteChannel
}
