/// Sidebar tab context-menu snapshot state extracted from `ContentView.swift`, which sits at its file-length budget.
struct SidebarTabItemContextMenuState {
    var hasDeferredWorkspaceObservationInvalidation = false
    var pendingWorkspaceSnapshot: SidebarWorkspaceSnapshotBuilder.Snapshot?
}
