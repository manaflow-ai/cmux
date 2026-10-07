public import Foundation

/// The 16-byte header of every `cmux.rd/1` datagram, little-endian:
/// `u8 version<<4 | flags`, `u8 kind`, `u16 stream`, `u32 frame`,
/// `u16 index`, `u16 count`, `u16 fec_count`, `u16 transport_seq`.
public struct RdDatagramHeader: Hashable, Sendable {
    public static let version: UInt8 = 1
    public static let length = 16
    /// Most shards of a frame that carries parity (one FEC block).
    public static let maxFecBlock: UInt32 = 255
    /// Most data shards of a frame without parity.
    public static let maxFrameShards: UInt32 = 4096

    public var flags: RdFrameFlags
    public var kind: RdDatagramKind
    public var stream: UInt16
    public var frame: UInt32
    public var index: UInt16
    public var count: UInt16
    public var fecCount: UInt16
    public var transportSeq: UInt16

    public init(flags: RdFrameFlags = [], kind: RdDatagramKind, stream: UInt16 = 0, frame: UInt32 = 0,
                index: UInt16 = 0, count: UInt16 = 0, fecCount: UInt16 = 0, transportSeq: UInt16 = 0) {
        self.flags = flags
        self.kind = kind
        self.stream = stream
        self.frame = frame
        self.index = index
        self.count = count
        self.fecCount = fecCount
        self.transportSeq = transportSeq
    }

    /// The header followed by `payload`.
    public func datagram(payload: Data) -> Data {
        var out = Data(capacity: Self.length + payload.count)
        out.append((Self.version << 4) | (flags.rawValue & RdFrameFlags.all.rawValue))
        out.append(kind.rawValue)
        out.appendRd(stream)
        out.appendRd(frame)
        out.appendRd(index)
        out.appendRd(count)
        out.appendRd(fecCount)
        out.appendRd(transportSeq)
        out.append(payload)
        return out
    }

    /// Splits a datagram into its header and payload, with cmux-rd-proto's checks.
    public static func decode(_ datagram: Data) throws(RdWireError) -> (RdDatagramHeader, Data) {
        var reader = RdByteReader(datagram)
        let first = try reader.u8()
        guard first >> 4 == version else { throw RdWireError("version \(first >> 4)") }
        let flags = RdFrameFlags(rawValue: first & 0x0f)
        guard RdFrameFlags.all.isSuperset(of: flags) else { throw RdWireError("flags") }
        guard let kind = RdDatagramKind(rawValue: try reader.u8()) else { throw RdWireError("kind") }
        let header = RdDatagramHeader(flags: flags, kind: kind, stream: try reader.u16(), frame: try reader.u32(),
                                      index: try reader.u16(), count: try reader.u16(), fecCount: try reader.u16(),
                                      transportSeq: try reader.u16())
        if kind == .video || kind == .fec {
            let total = UInt32(header.count) + UInt32(header.fecCount)
            let limit = header.fecCount == 0 ? maxFrameShards : maxFecBlock
            guard header.count != 0, UInt32(header.index) < total, total <= limit else {
                throw RdWireError("shard index or count")
            }
            guard (kind == .fec) == (header.index >= header.count) else { throw RdWireError("shard kind") }
        }
        return (header, reader.rest())
    }
}
