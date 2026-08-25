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

    public init(stream: RawByteStream) {
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

/// The legacy send-stream contract over one next-transport raw stream.
public struct BridgeSendStream: CmxIrohSendStream {
    private let stream: RawByteStream

    public init(stream: RawByteStream) {
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
    /// Both legacy halves over one raw stream.
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

    public init(stream: RawByteStream) {
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
