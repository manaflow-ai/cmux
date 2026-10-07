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

    private struct Wire: Codable {
        var t: String
        var counts: [String: Int]?
        var id: String?
        var kind: String?
        var label: String?
    }

    init?(data: Data) {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        switch wire.t {
        case "fin": self = .fin(counts: wire.counts ?? [:])
        case "fin.ack": self = .finAck
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
        case let .track(descriptor):
            wire = Wire(t: "track", id: descriptor.id, kind: descriptor.kind.rawValue, label: descriptor.label)
        }
        return (try? JSONEncoder().encode(wire)) ?? Data()
    }
}
