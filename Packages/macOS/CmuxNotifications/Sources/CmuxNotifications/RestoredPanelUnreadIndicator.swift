/// How a panel's unread indicator restored from a session snapshot
/// participates in workspace-level unread state.
///
/// Formerly `Workspace.RestoredPanelUnreadIndicator`.
public enum RestoredPanelUnreadIndicator: Equatable, Sendable {
    /// The restored indicator renders on the panel only.
    case visualOnly
    /// The restored indicator also marks the owning workspace unread.
    case workspaceUnread

    /// Maps the persisted `contributesToWorkspaceUnread` flag to a case.
    public init(contributesToWorkspaceUnread: Bool) {
        self = contributesToWorkspaceUnread ? .workspaceUnread : .visualOnly
    }

    /// Whether the restored indicator marks the owning workspace unread.
    public var contributesToWorkspaceUnread: Bool {
        self == .workspaceUnread
    }
}
