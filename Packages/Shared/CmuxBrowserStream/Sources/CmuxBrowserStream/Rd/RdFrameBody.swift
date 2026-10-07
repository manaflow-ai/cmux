public import Foundation

/// One encoded video frame before sharding: `u32 au_len`, `u64 t_capture_us`,
/// `u32 ref_frame`, then the Annex-B access unit. Trailing zero padding of
/// the last shard is ignored on decode.
public struct RdFrameBody: Hashable, Sendable {
    public static let prefixLength = 16
    /// `refFrame` of a frame that predicts from nothing (a keyframe).
    public static let refNone = UInt32.max

    public var captureMicros: UInt64
    public var refFrame: UInt32
    public var accessUnit: Data

    public init(captureMicros: UInt64, refFrame: UInt32, accessUnit: Data) {
        self.captureMicros = captureMicros
        self.refFrame = refFrame
        self.accessUnit = accessUnit
    }

    public var encoded: Data {
        var out = Data(capacity: Self.prefixLength + accessUnit.count)
        out.appendRd(UInt32(clamping: accessUnit.count))
        out.appendRd(captureMicros)
        out.appendRd(refFrame)
        out.append(accessUnit)
        return out
    }

    public init(decoding bytes: Data) throws(RdWireError) {
        var reader = RdByteReader(bytes)
        let length = Int(try reader.u32())
        captureMicros = try reader.u64()
        refFrame = try reader.u32()
        accessUnit = try reader.take(length)
    }
}
