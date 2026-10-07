public import Foundation

/// The newest input sequence number the host applied (`input_ack` payload, `u32`).
public struct RdInputAck: Hashable, Sendable {
    public var appliedSeq: UInt32

    public init(appliedSeq: UInt32) {
        self.appliedSeq = appliedSeq
    }

    public var encoded: Data {
        var out = Data()
        out.appendRd(appliedSeq)
        return out
    }

    public init(decoding bytes: Data) throws(RdWireError) {
        var reader = RdByteReader(bytes)
        appliedSeq = try reader.u32()
    }
}
