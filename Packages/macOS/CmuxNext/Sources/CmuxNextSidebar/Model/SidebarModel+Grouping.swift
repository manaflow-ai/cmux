import CmuxNextDesign

/// Group by Folder and Group by Status (`sidebar.groupBy`) on the model.
extension SidebarModel {
    /// Group by Folder: loose rows sit under folder headers.
    public var groupsByFolder: Bool { grouping.groupsByFolder }
    /// Group by Status (Debug `sidebar.groupByStatus`): rows sit under Needs you, Working, Done and No agent.
    public var groupsByStatus: Bool { grouping.byStatus }
    /// Group by Status's elbow children (`SidebarGrouping.elbowsChildren`), from the Debug toggle
    /// `sidebar.statusElbow` (`applyListPreferences`).
    public var elbowsChildren: Bool {
        get { grouping.elbowsChildren }
        set { grouping.elbowsChildren = newValue }
    }

    /// A Group by Status header's click: fold or unfold its rows. Needs you never folds.
    public func toggleStatusBucket(_ bucket: SidebarStatusBucket) {
        guard bucket.collapses else { return }
        if grouping.collapsed.remove(bucket) == nil { grouping.collapsed.insert(bucket) }
    }

    /// The grouping the list lays out: a held row that is no longer the active row moves to its
    /// own bucket, and keeps no hold for when it is active again.
    func settledGrouping() -> SidebarGrouping {
        if let held = grouping.held, held.row != activeWorkspaceID { grouping.held = nil }
        return grouping
    }

    /// Whether `new` (the patched `old`) changes which rows the list draws. The active row keeps
    /// its status bucket while it stays active (`SidebarGrouping.held`): a patch, not a move. With
    /// elbow children, a new parent moves the row.
    func movesRows(from old: SidebarWorkspace, to new: SidebarWorkspace) -> Bool {
        if groupsByFolder && old.folder != new.folder { return true }
        if groupsByStatus {
            // Elbow children: a row that gains, loses or changes its parent moves under it.
            if grouping.elbowsChildren && old.parentWorkspace != new.parentWorkspace { return true }
            let before = settledGrouping().bucket(old)
            if before != SidebarStatusBucket(new) {
                guard new.id == activeWorkspaceID else { return true }
                grouping.held = (new.id, before)
            }
        }
        return showWorkspaceTabs && !old.tabs.elementsEqual(new.tabs) { $0.id == $1.id && $0.kind == $1.kind }
    }
}
