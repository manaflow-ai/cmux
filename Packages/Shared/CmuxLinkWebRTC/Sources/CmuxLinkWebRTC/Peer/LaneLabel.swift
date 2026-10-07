public import CmuxLink

/// The data channel label of a lane (b2-webrtc.md section 6):
/// `cmux/1 <class> <priority>` with class `r`, `u` or `p<ms>`. The carrier's
/// own control channel is `cmux/1 ctl`.
public struct LaneLabel: Sendable, Hashable {
    public static let control = "cmux/1 ctl"
    static let prefix = "cmux/1"

    public let lane: TransportLane

    public init(lane: TransportLane) {
        self.lane = lane
    }

    /// Parses a peer's label; nil for foreign or malformed labels.
    public init?(label: String) {
        let parts = label.split(separator: " ")
        guard parts.count == 3, parts[0] == Self.prefix,
              let priority = Self.priorities.first(where: { $0.value == parts[2] })?.key else { return nil }
        let reliability: ChannelReliability
        switch parts[1] {
        case "r": reliability = .reliableOrdered
        case "u": reliability = .unreliableUnordered
        case let token where token.hasPrefix("p"):
            guard let ms = Int(token.dropFirst()), ms > 0 else { return nil }
            reliability = .partial(maxLifetime: .milliseconds(ms))
        default: return nil
        }
        lane = TransportLane(reliability: reliability, priority: priority)
    }

    public var label: String {
        "\(Self.prefix) \(classToken) \(Self.priorities[lane.priority] ?? "control")"
    }

    /// `maxPacketLifeTime` for partial lanes, clamped to SCTP's 16 bits.
    public var maxPacketLifeTimeMs: Int? {
        guard case let .partial(lifetime) = lane.reliability else { return nil }
        let ms = lifetime.components.seconds * 1000 + lifetime.components.attoseconds / 1_000_000_000_000_000
        return Int(min(max(ms, 1), 65535))
    }

    private var classToken: String {
        switch lane.reliability {
        case .reliableOrdered: "r"
        case .unreliableUnordered: "u"
        case .partial: "p\(maxPacketLifeTimeMs ?? 1)"
        }
    }

    private static let priorities: [ChannelPriority: Substring] = [
        .input: "input", .control: "control", .render: "render", .media: "media", .bulk: "bulk",
    ]
}
