/// B1's `signal.kind` (b1-control-do.md section 5).
public enum SignalingKind: String, Sendable, Hashable, Codable {
    case offer
    case answer
    case ice
    case iceEnd = "ice.end"
    case bye
}
