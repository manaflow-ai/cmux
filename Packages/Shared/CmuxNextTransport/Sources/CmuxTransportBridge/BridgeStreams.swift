import CMUXMobileCore
import CmuxIrohTransport
import CmuxNextTransport
import Foundation

/// The legacy receive-stream contract over one next-transport raw stream.
/// Serves the handshake remainder first, then live QUIC bytes; `nil` after a
/// clean peer finish. Single consumer, like every legacy lane half.
public actor BridgeReceiveStream: CmxIrohReceiveStream {
    private let stream: RawByteStream
    private var buffer: Data
    private var closed = false

    /// Wraps an already-open stream and takes ownership of its receive remainder.
    /// - Parameter stream: Raw stream with no other active receive consumer.
    public init(stream: RawByteStream) {
        self.stream = stream
        buffer = stream.handshakeRemainder
    }

    /// Reads handshake remainder before receiving more live bytes.
    /// - Parameter maximumByteCount: Positive upper bound for the returned chunk.
    /// - Returns: A bounded chunk, or nil after a clean peer finish.
    /// - Throws: An already-closed or underlying receive error.
    public func receive(maximumByteCount: Int) async throws -> Data? {
        guard !closed else { throw CmxIrohByteTransportError.alreadyClosed }
        if !buffer.isEmpty {
            let chunk = buffer.prefix(maximumByteCount)
            buffer.removeFirst(chunk.count)
            return Data(chunk)
        }
        var scratch = Data()
        return try await stream.read(maximumByteCount: maximumByteCount, consumedBuffer: &scratch)
    }

    /// Idempotently discards buffered input and stops the receive half.
    /// - Parameter errorCode: Application stop code sent to the peer.
    public func stop(errorCode: UInt64) async {
        guard !closed else { return }
        closed = true
        buffer.removeAll(keepingCapacity: false)
        await stream.stopReceiving(errorCode: errorCode)
    }
}

/// The legacy send-stream contract over one next-transport raw stream.
public struct BridgeSendStream: CmxIrohSendStream {
    private let stream: RawByteStream

    /// Adapts the send half of an already-open raw stream.
    /// - Parameter stream: Stream whose send lifecycle this adapter controls.
    public init(stream: RawByteStream) {
        self.stream = stream
    }

    /// Sends bytes unchanged with the raw stream's backpressure semantics.
    /// - Parameter data: Bytes to send in order.
    /// - Throws: The underlying stream-send error.
    public func send(_ data: Data) async throws {
        try await stream.write(data)
    }

    /// Finishes the send half without discarding queued bytes.
    /// - Throws: The underlying stream-finish error.
    public func finish() async throws {
        try await stream.finishSend()
    }

    /// Best-effort abort of the send half, discarding outstanding data.
    /// - Parameter errorCode: Application reset code sent to the peer.
    public func reset(errorCode: UInt64) async {
        await stream.resetSend(errorCode: errorCode)
    }

    /// Updates this stream's relative QUIC scheduling priority.
    /// - Parameter priority: Priority forwarded unchanged to QUIC.
    /// - Throws: The underlying priority-setting error.
    public func setPriority(_ priority: Int32) async throws {
        try await stream.setSendPriority(priority)
    }
}

extension CmxIrohBidirectionalStream {
    /// Both legacy halves over one raw stream.
    /// - Parameter stream: Already-open stream, not consumed by another adapter.
    public init(bridging stream: RawByteStream) {
        self.init(
            receiveStream: BridgeReceiveStream(stream: stream),
            sendStream: BridgeSendStream(stream: stream))
    }
}

/// The legacy control byte transport over one next-transport raw stream.
/// The stream is already open when this exists, so `connect()` is a no-op.
public actor BridgeByteTransport: CmxByteTransport {
    private let stream: RawByteStream
    private var buffer: Data
    private var closed = false

    /// Adapts an already-open stream, preserving bytes read during its handshake.
    /// - Parameter stream: Stream whose read/write lifecycle this adapter owns.
    public init(stream: RawByteStream) {
        self.stream = stream
        buffer = stream.handshakeRemainder
    }

    /// Validates that the already-connected transport has not been closed.
    /// - Throws: An already-closed error; this method never performs a fresh dial.
    public func connect() async throws {
        guard !closed else { throw CmxIrohByteTransportError.alreadyClosed }
    }

    /// Reads up to 64 KiB, serving handshake remainder before live bytes.
    /// - Returns: The next chunk, or nil after clean peer finish.
    /// - Throws: An already-closed or underlying stream-receive error.
    public func receive() async throws -> Data? {
        guard !closed else { throw CmxIrohByteTransportError.alreadyClosed }
        if !buffer.isEmpty {
            let chunk = buffer.prefix(1 << 16)
            buffer.removeFirst(chunk.count)
            return Data(chunk)
        }
        var scratch = Data()
        return try await stream.read(maximumByteCount: 1 << 16, consumedBuffer: &scratch)
    }

    /// Sends bytes unchanged while this adapter remains open.
    /// - Parameter data: Bytes to send in order.
    /// - Throws: An already-closed or underlying stream-send error.
    public func send(_ data: Data) async throws {
        guard !closed else { throw CmxIrohByteTransportError.alreadyClosed }
        try await stream.write(data)
    }

    /// Idempotently clears input, finishes sending, and stops receiving with code zero.
    public func close() async {
        guard !closed else { return }
        closed = true
        buffer.removeAll(keepingCapacity: false)
        if BridgeDebugLog.enabled {
            BridgeDebugLog.lanes.notice(
                """
                byte transport \(BridgeDebugLog.id(self), privacy: .public) close \
                (finish send + stop receive code=0)
                """)
        }
        try? await stream.finishSend()
        await stream.stopReceiving(errorCode: 0)
    }
}
