/// The compact agent activity state shown for a Pane Rack terminal tab.
public enum PaneRackAgentState: Equatable, Sendable {
    /// No agent work is currently in progress.
    case idle
    /// An agent is actively working.
    case working
    /// An agent is waiting for the user.
    case needsInput
    /// The agent process has ended.
    case ended
}
