/// Which sibling workspaces a `workspace.action` close targets (`close_others` /
/// `close_above` / `close_below`).
public enum ControlWorkspaceActionCloseScope: Sendable, Equatable {
    /// Every other unpinned workspace (legacy `close_others`).
    case others
    /// Unpinned workspaces above this one (legacy `close_above`).
    case above
    /// Unpinned workspaces below this one (legacy `close_below`).
    case below
}
