public import Foundation

/// The outcome of `workspace.group.ungroup`, including guarded generated-anchor
/// cleanup requested by automation.
public enum ControlWorkspaceGroupUngroupResolution: Sendable, Equatable {
    /// No TabManager resolved.
    case tabManagerUnavailable
    /// The requested group does not exist.
    case notFound
    /// The group was dissolved and its members were kept.
    case dissolved(keptWorkspaceCount: Int)
    /// The generated anchor was removed as part of dissolving an anchor-only
    /// group.
    case removedGeneratedAnchor(workspaceID: UUID)
    /// Cleanup was requested for a group that still has child members.
    case generatedAnchorRequiresAnchorOnly(memberWorkspaceCount: Int)
    /// The current anchor is not explicitly cmux-generated.
    case generatedAnchorNotOwned
    /// The generated anchor could not be removed.
    case generatedAnchorRemovalFailed
    /// A pinned empty group must be removed through explicit Delete Group.
    case emptyPinnedCannotUngroup
}
