public import CmuxIrohTransport
public import Foundation

/// Adapts one irx lane to the legacy stream seam so the proven app-level
/// payload handlers (terminal envelopes, artifact streaming) run over irx
/// lanes unchanged. The transport beneath is wholly irx; only the payload
/// contracts are shared.
public struct IrxReceiveStreamAdapter: CmxIrohReceiveStream {
    private let reader: IrxStreamReader

    public init(reader: IrxStreamReader) {
        self.reader = reader
    }

    public func receive(maximumByteCount: Int) async throws -> Data? {
        try await reader.readRaw(maximumByteCount: maximumByteCount)
    }

    public func stop(errorCode: UInt64) async {
        await reader.stop(errorCode: errorCode)
    }
}

public struct IrxSendStreamAdapter: CmxIrohSendStream {
    private let writer: IrxStreamWriter

    public init(writer: IrxStreamWriter) {
        self.writer = writer
    }

    public func send(_ data: Data) async throws {
        try await writer.write(data)
    }

    public func finish() async throws {
        await writer.finish()
    }

    public func reset(errorCode: UInt64) async {
        await writer.reset(errorCode: errorCode)
    }

    public func setPriority(_ priority: Int32) async throws {
        try await writer.setPriority(priority)
    }
}

extension IrxLaneStream {
    /// The legacy-seam view of this lane.
    public func bidirectional() -> CmxIrohBidirectionalStream {
        CmxIrohBidirectionalStream(
            receiveStream: IrxReceiveStreamAdapter(reader: reader),
            sendStream: IrxSendStreamAdapter(writer: writer)
        )
    }
}
