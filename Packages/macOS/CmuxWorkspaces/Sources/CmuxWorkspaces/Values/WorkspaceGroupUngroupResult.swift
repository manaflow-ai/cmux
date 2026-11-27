public import Foundation

/// Describes the result of dissolving a workspace group.
public enum WorkspaceGroupUngroupResult: Equatable, Sendable {
    /// The requested group does not exist.
    case groupNotFound
    /// The group was dissolved and its members were kept as ungrouped
    /// workspaces.
    case dissolved(keptWorkspaceCount: Int)
    /// The anchor-only generated workspace was explicitly removed while the
    /// group was dissolved.
    case removedGeneratedAnchor(workspaceID: UUID)
    /// Generated-anchor removal was requested for a group that still has child
    /// workspaces. The caller must dissolve it first or omit the removal flag.
    case generatedAnchorRequiresAnchorOnly(memberWorkspaceCount: Int)
    /// The anchor is not cmux-owned, so it cannot be removed by this safe path.
    case generatedAnchorNotOwned
    /// The generated anchor could not be removed without leaving an invalid
    /// window state.
    case generatedAnchorRemovalFailed
    /// A pinned empty group is retained until explicit Delete Group.
    case emptyPinnedCannotUngroup
}
