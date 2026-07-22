public import Foundation

/// The writable half of one Iroh QUIC stream.
public protocol CmxIrohSendStream: Sendable {
    /// Writes the complete buffer with QUIC backpressure.
    ///
    /// - Parameter data: The application bytes to send.
    /// - Throws: A transport error or `CancellationError`.
    func send(_ data: Data) async throws

    /// Gracefully finishes the send direction.
    ///
    /// - Throws: A transport error when the peer has already stopped the stream.
    func finish() async throws

    /// Aborts the send direction.
    ///
    /// - Parameter errorCode: The application error code carried by QUIC.
    func reset(errorCode: UInt64) async

    /// Assigns relative scheduling priority within the QUIC connection.
    ///
    /// - Parameter priority: The Iroh stream priority value.
    /// - Throws: A transport error when the stream is no longer writable.
    func setPriority(_ priority: Int32) async throws
}
