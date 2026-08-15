/// The highest-priority active-agent state for one sidebar panel.
public enum SidebarAgentPanelActivity: Sendable {
    /// At least one agent in the panel is running.
    case running

    /// At least one agent in the panel is waiting for user input.
    case needsInput

    /// The panel has no active agent state to count.
    case inactive
}
