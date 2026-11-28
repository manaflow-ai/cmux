public import Foundation

/// One ordered, reliable, bidirectional byte stream: an irx lane from the
/// phone, or a Unix socket to the daemon. The splice and the compat adapter
/// only see this protocol, so tests drive them with in-memory pipes.
public protocol MobileByteLane: Sendable {
    /// The next chunk, or nil at end of stream.
    func read(maximumBytes: Int) async throws -> Data?
    func write(_ data: Data) async throws
    /// Closes both directions. Idempotent.
    func close() async
}
