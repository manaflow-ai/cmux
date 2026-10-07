public import Foundation

/// Viewer-to-host feedback (cmux-rd-proto `Feedback`): the newest decodable
/// frame, decode time, a recovery request, arrivals and NACKs.
public struct RdFeedback: Hashable, Sendable {
    public static let maxArrivals = 128
    public static let maxNackFrames = 4
    public static let maxNackIndexes = 32

    public var ackedFrame: UInt32
    public var decodeMicros: UInt32
    public var needRecovery: Bool
    public var arrivals: [RdArrival]
    public var nacks: [RdNack]

    public init(ackedFrame: UInt32 = 0, decodeMicros: UInt32 = 0, needRecovery: Bool = false,
                arrivals: [RdArrival] = [], nacks: [RdNack] = []) {
        self.ackedFrame = ackedFrame
        self.decodeMicros = decodeMicros
        self.needRecovery = needRecovery
        self.arrivals = arrivals
        self.nacks = nacks
    }

    public var encoded: Data {
        var out = Data()
        out.appendRd(ackedFrame)
        out.appendRd(decodeMicros)
        out.append(needRecovery ? 1 : 0)
        let arrivals = arrivals.prefix(Self.maxArrivals)
        out.appendRd(UInt16(arrivals.count))
        for arrival in arrivals {
            out.appendRd(arrival.transportSeq)
            out.appendRd(arrival.arrivalMicros)
        }
        let nacks = nacks.prefix(Self.maxNackFrames)
        out.append(UInt8(nacks.count))
        for nack in nacks {
            out.appendRd(nack.frame)
            let indexes = nack.indexes.prefix(Self.maxNackIndexes)
            out.append(UInt8(indexes.count))
            for index in indexes { out.appendRd(index) }
        }
        return out
    }

    public init(decoding bytes: Data) throws(RdWireError) {
        var reader = RdByteReader(bytes)
        ackedFrame = try reader.u32()
        decodeMicros = try reader.u32()
        needRecovery = try reader.bool()
        var arrivals: [RdArrival] = []
        for _ in 0..<Int(try reader.u16()) {
            arrivals.append(RdArrival(transportSeq: try reader.u16(), arrivalMicros: try reader.u32()))
        }
        var nacks: [RdNack] = []
        for _ in 0..<Int(try reader.u8()) {
            let frame = try reader.u32()
            var indexes: [UInt16] = []
            for _ in 0..<Int(try reader.u8()) { indexes.append(try reader.u16()) }
            nacks.append(RdNack(frame: frame, indexes: indexes))
        }
        guard reader.isEmpty else { throw RdWireError("trailing bytes") }
        self.arrivals = arrivals
        self.nacks = nacks
    }
}
