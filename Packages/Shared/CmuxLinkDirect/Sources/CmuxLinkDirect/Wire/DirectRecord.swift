import CmuxLink
import Foundation

/// The plaintext of one encrypted transport record:
/// `u8 type | ...` (b4-direct.md section 4).
enum DirectRecord: Sendable, Hashable {
    /// One piece of a transport frame; `more` is false on the last piece.
    case segment(more: Bool, lane: TransportLane, bytes: Data)
    /// Graceful end of the transport.
    case close

    static let segmentType: UInt8 = 0x01
    static let closeType: UInt8 = 0x02
    static let segmentHeaderLength = 8
    /// The largest plaintext a record carries: Noise's 65535 minus the tag.
    static let maxPlaintext = NoiseCipherState.maxMessageLength - NoiseCipherState.tagLength
    static let maxSegmentBytes = maxPlaintext - segmentHeaderLength

    func encoded() -> Data {
        switch self {
        case .close:
            return Data([Self.closeType])
        case let .segment(more, lane, bytes):
            var data = Data(capacity: Self.segmentHeaderLength + bytes.count)
            data.append(Self.segmentType)
            data.append(more ? 1 : 0)
            let (reliability, lifetime) = Self.encode(lane.reliability)
            data.append(reliability)
            data.append(UInt8(lane.priority.rawValue))
            withUnsafeBytes(of: lifetime.littleEndian) { data.append(contentsOf: $0) }
            data.append(bytes)
            return data
        }
    }

    init(decoding data: Data) throws {
        let data = Data(data)
        guard let type = data.first else { throw DirectWireError.truncated }
        switch type {
        case Self.closeType:
            self = .close
        case Self.segmentType:
            guard data.count >= Self.segmentHeaderLength else { throw DirectWireError.truncated }
            let more = data[1] != 0
            let lifetime = UInt32(data[4]) | UInt32(data[5]) << 8 | UInt32(data[6]) << 16 | UInt32(data[7]) << 24
            let reliability = try Self.decode(reliability: data[2], lifetime: lifetime)
            guard let priority = ChannelPriority(rawValue: Int(data[3])) else {
                throw DirectWireError.unknownPriority(data[3])
            }
            self = .segment(
                more: more,
                lane: TransportLane(reliability: reliability, priority: priority),
                bytes: Data(data.dropFirst(Self.segmentHeaderLength))
            )
        default:
            throw DirectWireError.unknownRecordType(type)
        }
    }

    /// Splits one frame into segments that each fit a record.
    static func segments(of frame: TransportFrame) -> [DirectRecord] {
        let bytes = frame.bytes
        guard bytes.count > maxSegmentBytes else {
            return [.segment(more: false, lane: frame.lane, bytes: bytes)]
        }
        var records: [DirectRecord] = []
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = bytes.index(start, offsetBy: maxSegmentBytes, limitedBy: bytes.endIndex) ?? bytes.endIndex
            records.append(.segment(more: end < bytes.endIndex, lane: frame.lane, bytes: Data(bytes[start..<end])))
            start = end
        }
        return records
    }

    private static func encode(_ reliability: ChannelReliability) -> (UInt8, UInt32) {
        switch reliability {
        case .reliableOrdered:
            return (0, 0)
        case .unreliableUnordered:
            return (1, 0)
        case let .partial(maxLifetime):
            let millis = maxLifetime.components.seconds * 1000 + maxLifetime.components.attoseconds / 1_000_000_000_000_000
            return (2, UInt32(clamping: max(0, millis)))
        }
    }

    private static func decode(reliability: UInt8, lifetime: UInt32) throws -> ChannelReliability {
        switch reliability {
        case 0: return .reliableOrdered
        case 1: return .unreliableUnordered
        case 2: return .partial(maxLifetime: .milliseconds(Int64(lifetime)))
        default: throw DirectWireError.unknownReliability(reliability)
        }
    }
}
