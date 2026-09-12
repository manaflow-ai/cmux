import Foundation
import IrohLib

/// One raw application stream from the graduation bridge: unframed QUIC
/// bytes with the legacy transport's exact wire behavior (bounded reads,
/// backpressured writes, half-close both ways).
public struct RawByteStream: Sendable {
    let send: SendStream
    let recv: RecvStream
    let buffered: Data

    /// Reads at most `maximumByteCount`; nil on clean peer finish. The
    /// handshake leftover (if any) is served before live stream bytes.
    /// - Parameters:
    ///   - maximumByteCount: Positive upper bound for this read.
    ///   - consumedBuffer: Caller-owned remainder, initially ``handshakeRemainder``.
    /// - Returns: A bounded chunk, or nil after peer finish and buffer exhaustion.
    /// - Throws: The underlying QUIC receive error.
    public func read(maximumByteCount: Int, consumedBuffer: inout Data) async throws -> Data? {
        if !consumedBuffer.isEmpty {
            let chunk = consumedBuffer.prefix(maximumByteCount)
            consumedBuffer.removeFirst(chunk.count)
            return Data(chunk)
        }
        let data = try await recv.read(sizeLimit: UInt32(clamping: maximumByteCount))
        return data.isEmpty ? nil : data
    }

    /// Bytes the handshake decoder read past the `raw.open` frame. A consumer
    /// managing its own read buffer seeds it with this before live reads.
    public var handshakeRemainder: Data { buffered }

    /// Writes every byte, suspending when QUIC applies backpressure.
    /// - Parameter data: Bytes to send unchanged.
    /// - Throws: The underlying QUIC send error.
    public func write(_ data: Data) async throws {
        try await send.writeAll(buf: data)
    }

    /// Relative QUIC scheduling priority of the send half.
    /// - Parameter priority: Priority forwarded to the QUIC scheduler.
    /// - Throws: The underlying priority-setting error.
    public func setSendPriority(_ priority: Int32) async throws {
        try await send.setPriority(p: priority)
    }

    /// Finishes the send half without discarding queued bytes.
    /// - Throws: The underlying QUIC finish error.
    public func finishSend() async throws {
        try await send.finish()
    }

    /// Best-effort cancellation of the receive half without throwing during cleanup.
    /// - Parameter errorCode: Application stop code sent to the peer.
    public func stopReceiving(errorCode: UInt64) async {
        try? await recv.stop(errorCode: errorCode)
    }

    /// Best-effort abort of the send half, discarding outstanding data.
    /// - Parameter errorCode: Application reset code sent to the peer.
    public func resetSend(errorCode: UInt64) async {
        try? await send.reset(errorCode: errorCode)
    }
}
