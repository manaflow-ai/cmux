/// The lane protocol inside the tunnel (b3-webrtc-wg.md section 5). One
/// frame per overlay UDP datagram; little-endian.
enum LaneFrame: Equatable {
    /// A fragment of a reliable lane: `seq` numbers fragments.
    case reliable(lane: LaneID, seq: UInt32, first: Bool, last: Bool, payload: [UInt8])
    /// A fragment of an unordered or partial lane message.
    case message(lane: LaneID, id: UInt32, index: UInt16, count: UInt16, lifetimeMillis: UInt32, payload: [UInt8])
    /// `next` is the lowest sequence not yet received; bit i of `sack` says
    /// `next + 1 + i` arrived.
    case ack(lane: LaneID, next: UInt32, sack: UInt64)
    case close
    case closeAck

    static let version: UInt8 = 1
    static let reliableHeaderLength = 8
    static let messageHeaderLength = 16

    private static let dataType: UInt8 = 1
    private static let ackType: UInt8 = 2
    private static let closeType: UInt8 = 3
    private static let closeAckType: UInt8 = 4
    private static let firstFlag: UInt8 = 1
    private static let lastFlag: UInt8 = 2

    func encode() -> [UInt8] {
        switch self {
        case let .reliable(lane, seq, first, last, payload):
            let flags = (first ? Self.firstFlag : 0) | (last ? Self.lastFlag : 0)
            return [Self.version, Self.dataType, lane.byte, flags] + Self.le32(seq) + payload
        case let .message(lane, id, index, count, lifetime, payload):
            return [Self.version, Self.dataType, lane.byte, 0] + Self.le32(id)
                + Self.le16(index) + Self.le16(count) + Self.le32(lifetime) + payload
        case let .ack(lane, next, sack):
            return [Self.version, Self.ackType, lane.byte] + Self.le32(next) + Self.le64(sack)
        case .close:
            return [Self.version, Self.closeType]
        case .closeAck:
            return [Self.version, Self.closeAckType]
        }
    }

    static func decode(_ bytes: [UInt8]) -> LaneFrame? {
        guard bytes.count >= 2, bytes[0] == version else { return nil }
        switch bytes[1] {
        case dataType:
            guard bytes.count >= reliableHeaderLength, let lane = LaneID(byte: bytes[2]) else { return nil }
            let seq = readLE32(bytes, 4)
            if lane.kind == .reliable {
                return .reliable(
                    lane: lane, seq: seq,
                    first: bytes[3] & firstFlag != 0, last: bytes[3] & lastFlag != 0,
                    payload: Array(bytes[reliableHeaderLength...])
                )
            }
            guard bytes.count >= messageHeaderLength else { return nil }
            let index = UInt16(bytes[8]) | UInt16(bytes[9]) << 8
            let count = UInt16(bytes[10]) | UInt16(bytes[11]) << 8
            guard count > 0, index < count else { return nil }
            return .message(
                lane: lane, id: seq, index: index, count: count, lifetimeMillis: readLE32(bytes, 12),
                payload: Array(bytes[messageHeaderLength...])
            )
        case ackType:
            guard bytes.count == 15, let lane = LaneID(byte: bytes[2]) else { return nil }
            var sack: UInt64 = 0
            for index in 0..<8 { sack |= UInt64(bytes[7 + index]) << (8 * UInt64(index)) }
            return .ack(lane: lane, next: readLE32(bytes, 3), sack: sack)
        case closeType:
            return bytes.count == 2 ? .close : nil
        case closeAckType:
            return bytes.count == 2 ? .closeAck : nil
        default:
            return nil
        }
    }

    private static func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }

    private static func le32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) }
    }

    private static func le64(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    }

    private static func readLE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }
}
