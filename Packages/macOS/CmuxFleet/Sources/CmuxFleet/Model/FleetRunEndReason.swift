/// Describes why a Fleet run attempt ended.
public enum FleetRunEndReason: String, CaseIterable, Codable, Sendable {
    /// The agent stopped after producing a handoff artifact.
    case completedHandoff

    /// The agent exited without a handoff artifact.
    case exitedNoHandoff

    /// The agent process crashed or disappeared.
    case crashed

    /// Fleet killed the agent after a stall timeout.
    case stalledKilled

    /// The user cancelled the attempt.
    case userCancelled
}
