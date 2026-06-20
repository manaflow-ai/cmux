public import Foundation
public import CmuxSettings

/// The resolved destination for a new workspace created while a grouped
/// workspace is selected: the group it joins, the existing workspace the
/// placement is relative to, and the in-group placement.
///
/// Lifted one-for-one from the legacy `AppDelegate.WorkspaceGroupNewWorkspaceTarget`
/// nested struct. It is a pure `Sendable` value (the placement type
/// ``CmuxSettings/WorkspaceGroupNewPlacement`` already lives in `CmuxSettings`),
/// computed by ``WorkspaceCreationActionCoordinator/workspaceGroupNewWorkspaceTarget(in:)``
/// from the window's selected-workspace group state and threaded back into the
/// in-group create / configured-action paths.
public struct WorkspaceGroupNewWorkspaceTarget: Sendable, Equatable {
    /// The workspace group the new workspace joins.
    public let groupId: UUID
    /// The currently selected workspace the placement is resolved relative to.
    public let referenceWorkspaceId: UUID
    /// Where the new workspace lands within the group.
    public let placement: WorkspaceGroupNewPlacement

    /// Creates a resolved in-group new-workspace destination.
    public init(
        groupId: UUID,
        referenceWorkspaceId: UUID,
        placement: WorkspaceGroupNewPlacement
    ) {
        self.groupId = groupId
        self.referenceWorkspaceId = referenceWorkspaceId
        self.placement = placement
    }
}
