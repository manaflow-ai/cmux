/// A session's priority tier, used as a matrix row.
public enum SessionPriorityTier: String, CaseIterable, Codable, Sendable {
    case urgent, slow
}
