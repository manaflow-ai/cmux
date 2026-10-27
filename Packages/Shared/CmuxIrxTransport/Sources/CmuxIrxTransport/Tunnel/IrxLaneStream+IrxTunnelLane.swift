#if canImport(IrohLib)
public import Foundation

/// A QUIC lane is the production ``IrxTunnelLane``.
extension IrxLaneStream: IrxTunnelLane {
    public func readRaw(maximumByteCount: Int) async throws -> Data? {
        try await reader.readRaw(maximumByteCount: maximumByteCount)
    }

    public func write(_ data: Data) async throws {
        try await writer.write(data)
    }

    public func writeFrame(_ value: some Encodable & Sendable) async throws {
        try await writer.writeControlFrame(value)
    }

    public func finish() async {
        await writer.finish()
    }

    public func abort() async {
        await writer.reset(errorCode: 3)
        await reader.stop(errorCode: 3)
    }
}
#endif
