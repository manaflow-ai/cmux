import CmuxLink
import Foundation

/// The carrier's own messages on the `cmux/1 ctl` data channel (JSON). They
/// never carry link frames (b2-webrtc.md section 6).
enum CarrierControlMessage: Sendable, Hashable {
    /// Graceful close: how many messages the sender sent on each reliable lane.
    case fin(counts: [String: Int])
    case finAck
    /// Describes a media track the sender added (matched by track id).
    case track(MediaTrackDescriptor)
    /// Flow credit: total reliable lane message bytes the sender of this
    /// message has received so far (cumulative), so the peer's scheduler
    /// keeps at most `inFlightWindowBytes` unacknowledged.
    case credit(received: Int)

    private struct Wire: Codable {
        var t: String
        var counts: [String: Int]?
        var id: String?
        var kind: String?
        var label: String?
        var received: Int?
    }

    init?(data: Data) {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        switch wire.t {
        case "fin": self = .fin(counts: wire.counts ?? [:])
        case "fin.ack": self = .finAck
        case "credit":
            guard let received = wire.received else { return nil }
            self = .credit(received: received)
        case "track":
            guard let id = wire.id, let raw = wire.kind, let kind = MediaTrackKind(rawValue: raw) else { return nil }
            self = .track(MediaTrackDescriptor(id: id, kind: kind, label: wire.label ?? ""))
        default: return nil
        }
    }

    var data: Data {
        let wire: Wire
        switch self {
        case let .fin(counts): wire = Wire(t: "fin", counts: counts)
        case .finAck: wire = Wire(t: "fin.ack")
        case let .credit(received): wire = Wire(t: "credit", received: received)
        case let .track(descriptor):
            wire = Wire(t: "track", id: descriptor.id, kind: descriptor.kind.rawValue, label: descriptor.label)
        }
        return (try? JSONEncoder().encode(wire)) ?? Data()
    }
}
