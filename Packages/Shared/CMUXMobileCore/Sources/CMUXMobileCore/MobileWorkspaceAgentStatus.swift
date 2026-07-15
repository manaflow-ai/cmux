/// The effective coding-agent lifecycle reported for a mirrored tab.
public enum MobileWorkspaceAgentStatus: String, Codable, Equatable, Sendable {
    /// The Mac knows an agent is associated with the tab but has no current lifecycle report.
    case unknown
    /// The agent is actively working.
    case running
    /// The agent is idle and does not need input.
    case idle
    /// The agent is blocked waiting for user input.
    case needsInput = "needs_input"
}
