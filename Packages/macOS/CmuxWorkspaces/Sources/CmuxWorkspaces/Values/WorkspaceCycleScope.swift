/// The ordered workspace set used to resolve a cycle destination.
public enum WorkspaceCycleScope: Sendable {
    /// Cycles through every workspace in the window.
    case window

    /// Cycles through the focused group's non-anchor member workspaces.
    case focusedGroupMembers
}
