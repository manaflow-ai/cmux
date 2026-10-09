public import Foundation

/// A byte stream to a VNC server (TCP in production, a pipe in tests).
/// One reader and any number of writers at a time.
public protocol RfbTransport: Sendable {
    /// Exactly `count` bytes; throws `RfbError.closed` at end of stream.
    func read(exactly count: Int) async throws -> Data
    func write(_ data: Data) async throws
    func close() async
}
