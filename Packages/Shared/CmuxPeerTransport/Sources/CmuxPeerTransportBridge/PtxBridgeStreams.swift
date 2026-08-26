import CMUXMobileCore
import CmuxIrohTransport
import CmuxPeerTransport
import Foundation

/// The legacy receive-stream contract over one v2 raw stream. Serves the
/// handshake remainder first, then live QUIC bytes; nil after a clean peer
/// finish. Single consumer, like every legacy lane half.
public actor PtxBridgeReceiveStream: CmxIrohReceiveStream {
    private let stream: PtxRawStream
    private var buffer: Data

    public init(stream: PtxRawStream) {
        self.stream = stream
        buffer = stream.handshakeRemainder
    }

    public func receive(maximumByteCount: Int) async throws -> Data? {
        if !buffer.isEmpty {
            let chunk = buffer.prefix(maximumByteCount)
            buffer.removeFirst(chunk.count)
            return Data(chunk)
        }
        var scratch = Data()
        return try await stream.read(maximumByteCount: maximumByteCount, consumedBuffer: &scratch)
    }

    public func stop(errorCode: UInt64) async {
        await stream.stopReceiving(errorCode: errorCode)
    }
}

/// The legacy send-stream contract over one v2 raw stream.
public struct PtxBridgeSendStream: CmxIrohSendStream {
    private let stream: PtxRawStream

    public init(stream: PtxRawStream) {
        self.stream = stream
    }

    public func send(_ data: Data) async throws {
        try await stream.write(data)
    }

    public func finish() async throws {
        try await stream.finishSend()
    }

    public func reset(errorCode: UInt64) async {
        await stream.resetSend(errorCode: errorCode)
    }

    public func setPriority(_ priority: Int32) async throws {
        try await stream.setSendPriority(priority)
    }
}

extension CmxIrohBidirectionalStream {
    /// Both legacy halves over one v2 raw stream.
    public init(bridging stream: PtxRawStream) {
        self.init(
            receiveStream: PtxBridgeReceiveStream(stream: stream),
            sendStream: PtxBridgeSendStream(stream: stream))
    }
}

/// The legacy control byte transport over one v2 raw stream. The stream is
/// already open when this exists, so `connect()` is a no-op.
public actor PtxBridgeByteTransport: CmxByteTransport {
    private let stream: PtxRawStream
    private var buffer: Data

    public init(stream: PtxRawStream) {
        self.stream = stream
        buffer = stream.handshakeRemainder
    }

    public func connect() async throws {}

    public func receive() async throws -> Data? {
        if !buffer.isEmpty {
            let chunk = buffer.prefix(1 << 16)
            buffer.removeFirst(chunk.count)
            return Data(chunk)
        }
        var scratch = Data()
        return try await stream.read(maximumByteCount: 1 << 16, consumedBuffer: &scratch)
    }

    public func send(_ data: Data) async throws {
        try await stream.write(data)
    }

    public func close() async {
        try? await stream.finishSend()
        await stream.stopReceiving(errorCode: 0)
    }
}
