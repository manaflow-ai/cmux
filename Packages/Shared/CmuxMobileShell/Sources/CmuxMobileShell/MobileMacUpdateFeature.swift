/// A mobile-visible feature gated on a Mac host capability.
///
/// Raw values are stable identifiers used in dismissal signatures and analytics.
public enum MobileMacUpdateFeature: String, CaseIterable, Sendable {
    /// Renaming and pinning workspaces.
    case workspaceActions

    /// Marking workspaces as read or unread.
    case workspaceReadState

    /// Closing workspaces.
    case workspaceClose

    /// Organizing workspaces into groups.
    case workspaceGroups

    /// Reordering workspaces.
    case workspaceMove

    /// Moving and grouping workspaces.
    case workspaceGroupActions

    /// Creating workspaces inside groups.
    case workspaceCreateInGroup

    /// Creating workspace groups.
    case workspaceGroupCreate
}
