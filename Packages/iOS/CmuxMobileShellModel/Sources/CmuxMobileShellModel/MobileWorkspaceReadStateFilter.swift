/// Read-state narrowing for workspace list filters.
public enum MobileWorkspaceReadStateFilter: String, CaseIterable, Hashable, Sendable {
    /// No read-state narrowing; every row matches.
    case all
    /// Only workspaces with unread activity.
    case unread
}
