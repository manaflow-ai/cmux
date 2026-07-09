public import Foundation

/// The flattened, value-typed metadata for one window workspace at
/// session-save time: enough for ``SessionSnapshotBuilder`` to run the
/// restorable filter and cap, resolve the selected-workspace index, and build
/// the per-group ordered restorable-member map without reaching into the live
/// `Workspace`.
///
/// The host app flattens each workspace into one of these (the live
/// `Workspace.isRestorableInSessionSnapshot` read stays app-side); the
/// expensive per-workspace snapshot itself is supplied separately as a closure
/// to ``SessionSnapshotBuilder/assembleTabManagerSnapshot(inputs:selectedTabId:groups:maxWorkspaces:groupCoordinator:workspaceSnapshot:)``
/// so it is only built for the workspaces that survive the filter and cap.
public struct SessionWorkspaceSnapshotInput: Sendable {
    /// The workspace's stable id (legacy `Workspace.id`).
    public let id: UUID
    /// The id of the workspace group this workspace belongs to, if any
    /// (legacy `Workspace.groupId`).
    public let groupId: UUID?
    /// Whether this workspace is eligible for the persisted session snapshot
    /// (legacy `Workspace.isRestorableInSessionSnapshot`).
    public let isRestorable: Bool

    /// Creates a flattened workspace snapshot input.
    ///
    /// - Parameters:
    ///   - id: the workspace's stable id.
    ///   - groupId: the workspace group id, or nil when ungrouped.
    ///   - isRestorable: whether the workspace is eligible for the snapshot.
    public init(id: UUID, groupId: UUID?, isRestorable: Bool) {
        self.id = id
        self.groupId = groupId
        self.isRestorable = isRestorable
    }
}
