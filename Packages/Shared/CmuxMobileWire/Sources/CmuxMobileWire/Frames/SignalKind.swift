/// The kind of an ephemeral `signal` frame (WebRTC signaling through HostDO).
public enum SignalKind: String, CaseIterable, Hashable, Sendable, Codable {
    case offer, answer, ice
    case iceEnd = "ice.end"
    case bye
}
