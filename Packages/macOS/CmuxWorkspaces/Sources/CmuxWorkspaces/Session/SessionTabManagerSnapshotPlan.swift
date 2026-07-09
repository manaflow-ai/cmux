/// The value-typed result of
/// ``SessionSnapshotBuilder/assembleTabManagerSnapshot(inputs:selectedTabId:groups:maxWorkspaces:groupCoordinator:workspaceSnapshot:)``:
/// the three pieces the host folds into its app-side tab-manager session
/// snapshot.
///
/// Generic over the app-side per-workspace snapshot type because that value is
/// owned by the app target (it speaks live `Workspace` panel/terminal state);
/// the builder only filters, orders, and indexes it, so it never needs to name
/// the concrete snapshot type.
public struct SessionTabManagerSnapshotPlan<WorkspaceSnapshot> {
    /// The 0-based position of the selected workspace within
    /// ``workspaceSnapshots``, or nil when no restorable workspace is selected
    /// (legacy `selectedWorkspaceIndex`).
    public let selectedWorkspaceIndex: Int?
    /// The per-workspace snapshots for the restorable, capped workspaces, in
    /// tab order (legacy `workspaceSnapshots`).
    public let workspaceSnapshots: [WorkspaceSnapshot]
    /// The persisted group snapshots, or nil when no group survives (legacy
    /// `groupSnapshots`).
    public let groupSnapshots: [SessionWorkspaceGroupSnapshot]?

    /// Creates a tab-manager snapshot plan.
    ///
    /// - Parameters:
    ///   - selectedWorkspaceIndex: the selected workspace's position within
    ///     `workspaceSnapshots`, or nil.
    ///   - workspaceSnapshots: the restorable, capped per-workspace snapshots.
    ///   - groupSnapshots: the persisted group snapshots, or nil when none
    ///     survive.
    public init(
        selectedWorkspaceIndex: Int?,
        workspaceSnapshots: [WorkspaceSnapshot],
        groupSnapshots: [SessionWorkspaceGroupSnapshot]?
    ) {
        self.selectedWorkspaceIndex = selectedWorkspaceIndex
        self.workspaceSnapshots = workspaceSnapshots
        self.groupSnapshots = groupSnapshots
    }
}

extension SessionTabManagerSnapshotPlan: Sendable where WorkspaceSnapshot: Sendable {}
