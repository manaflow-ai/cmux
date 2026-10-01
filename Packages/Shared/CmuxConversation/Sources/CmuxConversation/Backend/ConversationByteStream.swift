public import Foundation

/// A raw, ordered byte connection to a backend's host: a Unix socket on the
/// same Mac, or a stream over the paired Mac's Iroh link.
///
/// Transports implement this; backends frame their protocol on top.
public protocol ConversationByteStream: Sendable {
    /// Reads up to `maximumBytes`.
    /// - Parameter maximumBytes: The most bytes to return.
    /// - Returns: The next bytes, or `nil` once the peer closed the stream.
    /// - Throws: A transport error.
    func read(maximumBytes: Int) async throws -> Data?
    /// Writes all of `data`.
    /// - Parameter data: The bytes to send.
    /// - Throws: A transport error, such as a closed stream.
    func write(_ data: Data) async throws
    /// Closes both directions. Safe to call more than once.
    func close() async
}
