public import Foundation

/// One TCP connection from this Mac to its own loopback. Every call
/// suspends until done, so the forwarder never reads ahead of a send.
public protocol MobileLoopbackSocket: Sendable {
    /// The next bytes, or nil once the peer finished sending.
    func read(maximum: Int) async throws -> Data?
    func write(_ data: Data) async throws
    /// Half close: no more bytes from us.
    func finishWriting() async
    /// Aborts both directions; a pending read returns.
    func close() async
}
