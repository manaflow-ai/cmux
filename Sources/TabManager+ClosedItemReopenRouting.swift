import CmuxWorkspaces
import Foundation

/// The per-window host for the CmuxWorkspaces ``ClosedItemReopenRouting``: the
/// `AppDelegate.shared` delegation guards, the closed-item history store
/// reads/mutations, the live `Workspace` lookup plus its closed-panel restore,
/// and the entry → ``ClosedItemReopenRoute`` mapping. The coordinator owns the
/// routing and the panel-restore focus ordering; these witnesses bottom out in
/// the app-target store, registry, and selection.
///
/// `selectWorkspace(_:)` and `rememberFocusedSurface(workspaceId:surfaceId:)`
/// are already witnessed by the ``FocusHistoryHosting`` conformance
/// (TabManager+FocusHistoryHosting); one declaration satisfies both seams, so
/// they are not repeated here. The `.workspace` route runs the coordinator's own
/// ``ClosedItemReopenRouting/restoreClosedWorkspace(_:)``, which inverts the
/// add/replay/guard/group-normalize/select/focus-flash sequence through the
/// workspace-restore witnesses below; `RestoredWorkspace` is the live `Workspace`.
extension TabManager: ClosedPanelRestoreHosting {
    typealias Entry = ClosedItemHistoryEntry
    typealias PanelEntry = ClosedPanelHistoryEntry
    typealias WorkspaceEntry = ClosedWorkspaceHistoryEntry
    typealias RemovedRecord = ClosedItemRemovedHistoryRecord
    typealias RestoredWorkspace = Workspace

    var focusHistory: any FocusHistoryNavigating { focusHistoryNavigation }

    func reopenMostRecentlyClosedItemViaAppDelegate() -> Bool? {
        guard let appDelegate = AppDelegate.shared else { return nil }
        return appDelegate.reopenMostRecentlyClosedItem(preferredTabManager: self)
    }

    func reopenClosedHistoryItemViaAppDelegate(id: UUID) -> Bool? {
        guard let appDelegate = AppDelegate.shared else { return nil }
        return appDelegate.reopenClosedHistoryItem(id: id, preferredTabManager: self)
    }

    func restoreFirstRestorable(using restore: (ClosedItemHistoryEntry) -> Bool) -> Bool {
        closedItemHistory.restoreFirstRestorable(using: restore)
    }

    func removeRecord(id: UUID) -> ClosedItemRemovedHistoryRecord? {
        guard let removed = closedItemHistory.removeRecord(id: id) else { return nil }
        return ClosedItemRemovedHistoryRecord(record: removed.record, index: removed.index)
    }

    func entry(of removed: ClosedItemRemovedHistoryRecord) -> ClosedItemHistoryEntry {
        removed.record.entry
    }

    func reinsertRemovedRecord(_ removed: ClosedItemRemovedHistoryRecord) {
        closedItemHistory.insert(removed.record, at: removed.index)
    }

    func route(
        for entry: ClosedItemHistoryEntry
    ) -> ClosedItemReopenRoute<ClosedPanelHistoryEntry, ClosedWorkspaceHistoryEntry> {
        switch entry {
        case .panel(let panelEntry):
            return .panel(panelEntry)
        case .workspace(let workspaceEntry):
            return .workspace(workspaceEntry)
        case .window:
            return .window
        }
    }

    func panelRestoreWorkspaceId(for entry: ClosedPanelHistoryEntry) -> UUID? {
        tabs.first(where: { $0.id == entry.workspaceId })?.id
    }

    func restoreClosedPanelInWorkspace(
        _ entry: ClosedPanelHistoryEntry,
        excludingStableIdentities: Set<UUID>
    ) -> UUID? {
        tabs.first(where: { $0.id == entry.workspaceId })?.restoreClosedPanel(
            entry,
            excludingStableIdentities: excludingStableIdentities
        )
    }

    func remapPanelAnchorIds(for entry: ClosedPanelHistoryEntry, to panelId: UUID) {
        closedItemHistory.remapPanelAnchorIds(from: entry.snapshot.id, to: panelId)
    }

    // MARK: Workspace-restore witnesses

    func snapshotHasRestorablePanels(_ entry: ClosedWorkspaceHistoryEntry) -> Bool {
        entry.snapshot.hasRestorablePanels
    }

    func entryWorkspaceId(_ entry: ClosedWorkspaceHistoryEntry) -> UUID {
        entry.workspaceId
    }

    func entryWorkspaceIndex(_ entry: ClosedWorkspaceHistoryEntry) -> Int {
        entry.workspaceIndex
    }

    func addRestoredWorkspace(for entry: ClosedWorkspaceHistoryEntry) -> Workspace {
        addWorkspace(
            title: entry.snapshot.customTitle ?? entry.snapshot.processTitle,
            workingDirectory: entry.snapshot.currentDirectory,
            select: false,
            autoWelcomeIfNeeded: false
        )
    }

    func restoreSessionSnapshot(
        _ entry: ClosedWorkspaceHistoryEntry,
        into workspace: Workspace,
        excludingStableIdentities: Set<UUID>
    ) -> [UUID: UUID] {
        workspace.restoreSessionSnapshot(
            entry.snapshot,
            excludingStableIdentities: excludingStableIdentities
        )
    }

    func closeRestoredWorkspace(_ workspace: Workspace) {
        closeWorkspace(workspace, recordHistory: false)
    }

    func restoredWorkspaceHasNoPanels(_ workspace: Workspace) -> Bool {
        workspace.panels.isEmpty
    }

    func restoredWorkspaceId(_ workspace: Workspace) -> UUID {
        workspace.id
    }

    func restoredWorkspaceGroupId(_ workspace: Workspace) -> UUID? {
        workspace.groupId
    }

    func clearRestoredWorkspaceGroupId(_ workspace: Workspace) {
        workspace.groupId = nil
    }

    func restoredWorkspaceFocusedPanelId(_ workspace: Workspace) -> UUID? {
        workspace.focusedPanelId
    }

    func hasWorkspaceGroup(id: UUID) -> Bool {
        workspaceGroups.contains(where: { $0.id == id })
    }

    func hasAnyWorkspaceGroups() -> Bool {
        !workspaceGroups.isEmpty
    }

    func remapPanelWorkspaceIds(from oldWorkspaceId: UUID, to newWorkspaceId: UUID, panelIdMap: [UUID: UUID]) {
        closedItemHistory.remapPanelWorkspaceIds(
            from: oldWorkspaceId,
            to: newWorkspaceId,
            panelIdMap: panelIdMap
        )
    }

    func reinsertRestoredWorkspace(id workspaceId: UUID, atIndex workspaceIndex: Int) {
        if let currentIndex = tabs.firstIndex(where: { $0.id == workspaceId }) {
            let removed = tabs.remove(at: currentIndex)
            let insertIndex = min(max(workspaceIndex, 0), tabs.count)
            tabs.insert(removed, at: insertIndex)
        }
    }

    func normalizeWorkspaceGroupContiguity() {
        workspaces.normalizeWorkspaceGroupContiguity()
    }

    func triggerFocusFlash(_ workspace: Workspace, panelId: UUID) {
        workspace.triggerFocusFlash(panelId: panelId)
    }
}
