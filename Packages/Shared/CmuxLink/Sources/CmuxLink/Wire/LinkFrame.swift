public import Foundation

/// The session protocol between two `LinkSession`s, carried as opaque bytes
/// on transport lanes (a3-link.md section 10). Layout: `[u8 version=1]
/// [u8 kind]` then the fields below, little-endian. The Rust codec (lane B5)
/// replays `Tests/CmuxLinkTests/Fixtures/link-frames.json`.
public enum LinkFrame: Sendable, Hashable {
    /// Dialer to host, first frame on every transport. `epoch` 0 = new.
    case hello(sessionID: UUID, epoch: UInt64)
    /// Host to dialer. `resumed` false means a new epoch: cursors reset.
    case welcome(epoch: UInt64, resumed: Bool)
    /// Declares or re-declares a channel with the opener's receive cursor.
    case open(channel: UInt32, descriptor: ChannelDescriptor, cursorEpoch: UInt64, cursorRevision: UInt64)
    /// Answers `open` with the acceptor's receive cursor.
    case openAck(channel: UInt32, epoch: UInt64, revision: UInt64)
    case data(channel: UInt32, revision: UInt64, payload: Data)
    /// Cumulative: the receiver consumed every revision up to `revision`.
    case ack(channel: UInt32, revision: UInt64)
    /// Closes a channel; the peer echoes it once.
    case close(channel: UInt32)
    /// Revisions up to `resumeAfter` will never arrive.
    case gap(channel: UInt32, resumeAfter: UInt64, reason: GapReason)
    case sessionClose(SessionCloseCode)

    public static let version: UInt8 = 1
    /// Bytes a `data` frame adds around its payload.
    public static let dataOverhead = 14

    private enum Kind: UInt8 {
        case hello = 1, welcome, open, openAck, data, ack, close, gap, sessionClose
    }

    public func encoded() -> Data {
        var writer = ByteWriter(capacity: 32)
        writer.u8(Self.version)
        switch self {
        case let .hello(sessionID, epoch):
            writer.u8(Kind.hello.rawValue)
            writer.bytes(withUnsafeBytes(of: sessionID.uuid) { Data($0) })
            writer.u64(epoch)
        case let .welcome(epoch, resumed):
            writer.u8(Kind.welcome.rawValue)
            writer.u64(epoch)
            writer.u8(resumed ? 1 : 0)
        case let .open(channel, descriptor, cursorEpoch, cursorRevision):
            writer.u8(Kind.open.rawValue)
            writer.u32(channel)
            switch descriptor.reliability {
            case .reliableOrdered:
                writer.u8(0)
                writer.u32(0)
            case .unreliableUnordered:
                writer.u8(1)
                writer.u32(0)
            case let .partial(maxLifetime):
                writer.u8(2)
                writer.u32(UInt32(clamping: Self.milliseconds(maxLifetime)))
            }
            writer.u8(UInt8(descriptor.priority.rawValue))
            writer.u32(UInt32(clamping: descriptor.budgetBytes))
            writer.u64(cursorEpoch)
            writer.u64(cursorRevision)
            let name = Data(descriptor.stream.utf8)
            writer.u16(UInt16(clamping: name.count))
            writer.bytes(name.prefix(Int(UInt16.max)))
        case let .openAck(channel, epoch, revision):
            writer.u8(Kind.openAck.rawValue)
            writer.u32(channel)
            writer.u64(epoch)
            writer.u64(revision)
        case let .data(channel, revision, payload):
            writer.u8(Kind.data.rawValue)
            writer.u32(channel)
            writer.u64(revision)
            writer.bytes(payload)
        case let .ack(channel, revision):
            writer.u8(Kind.ack.rawValue)
            writer.u32(channel)
            writer.u64(revision)
        case let .close(channel):
            writer.u8(Kind.close.rawValue)
            writer.u32(channel)
        case let .gap(channel, resumeAfter, reason):
            writer.u8(Kind.gap.rawValue)
            writer.u32(channel)
            writer.u64(resumeAfter)
            writer.u8(reason.rawValue)
        case let .sessionClose(code):
            writer.u8(Kind.sessionClose.rawValue)
            writer.u8(code.rawValue)
        }
        return writer.data
    }

    public init(decoding data: Data) throws(LinkFrameError) {
        var reader = ByteReader(data)
        let version = try reader.u8()
        guard version == Self.version else { throw .unsupportedVersion(version) }
        let rawKind = try reader.u8()
        guard let kind = Kind(rawValue: rawKind) else { throw .unknownKind(rawKind) }
        switch kind {
        case .hello:
            let raw = try reader.bytes(16)
            let uuid = raw.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }
            self = .hello(sessionID: UUID(uuid: uuid), epoch: try reader.u64())
        case .welcome:
            let epoch = try reader.u64()
            let resumed = try reader.u8()
            guard resumed <= 1 else { throw .invalidField("resumed") }
            self = .welcome(epoch: epoch, resumed: resumed == 1)
        case .open:
            let channel = try reader.u32()
            let reliabilityCode = try reader.u8()
            let lifetime = try reader.u32()
            let reliability: ChannelReliability
            switch reliabilityCode {
            case 0: reliability = .reliableOrdered
            case 1: reliability = .unreliableUnordered
            case 2: reliability = .partial(maxLifetime: .milliseconds(Int(lifetime)))
            default: throw .invalidField("reliability")
            }
            guard let priority = ChannelPriority(rawValue: Int(try reader.u8())) else {
                throw .invalidField("priority")
            }
            let budget = try reader.u32()
            let cursorEpoch = try reader.u64()
            let cursorRevision = try reader.u64()
            let nameLength = try reader.u16()
            guard let stream = String(data: try reader.bytes(Int(nameLength)), encoding: .utf8) else {
                throw .invalidField("stream")
            }
            let descriptor = ChannelDescriptor(
                stream: stream, reliability: reliability, priority: priority, budgetBytes: Int(budget)
            )
            self = .open(
                channel: channel, descriptor: descriptor,
                cursorEpoch: cursorEpoch, cursorRevision: cursorRevision
            )
        case .openAck:
            self = .openAck(channel: try reader.u32(), epoch: try reader.u64(), revision: try reader.u64())
        case .data:
            let channel = try reader.u32()
            let revision = try reader.u64()
            self = .data(channel: channel, revision: revision, payload: reader.rest())
        case .ack:
            self = .ack(channel: try reader.u32(), revision: try reader.u64())
        case .close:
            self = .close(channel: try reader.u32())
        case .gap:
            let channel = try reader.u32()
            let resumeAfter = try reader.u64()
            guard let reason = GapReason(rawValue: try reader.u8()) else { throw .invalidField("reason") }
            self = .gap(channel: channel, resumeAfter: resumeAfter, reason: reason)
        case .sessionClose:
            guard let code = SessionCloseCode(rawValue: try reader.u8()) else { throw .invalidField("code") }
            self = .sessionClose(code)
        }
        guard reader.isAtEnd else { throw .trailingBytes }
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
    }
}
