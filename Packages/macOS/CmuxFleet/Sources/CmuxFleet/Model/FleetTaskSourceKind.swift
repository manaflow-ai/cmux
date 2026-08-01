/// Describes where a Fleet task was sourced from.
public enum FleetTaskSourceKind: String, CaseIterable, Codable, Sendable {
    /// A task created in cmux's local Fleet queue.
    case local

    /// A task mirrored from GitHub Issues.
    case github
}
