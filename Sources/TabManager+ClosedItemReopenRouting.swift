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
/// they are not repeated here. `restoreClosedWorkspace(_:)` is the window god's
/// existing method (still owned there until its own slice), reached only for the
/// `.workspace` route.
extension TabManager: ClosedPanelRestoreHosting {
    typealias Entry = ClosedItemHistoryEntry
    typealias PanelEntry = ClosedPanelHistoryEntry
    typealias WorkspaceEntry = ClosedWorkspaceHistoryEntry
    typealias RemovedRecord = ClosedItemRemovedHistoryRecord

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

    func restoreClosedPanelInWorkspace(_ entry: ClosedPanelHistoryEntry) -> UUID? {
        tabs.first(where: { $0.id == entry.workspaceId })?.restoreClosedPanel(entry)
    }

    func remapPanelAnchorIds(for entry: ClosedPanelHistoryEntry, to panelId: UUID) {
        closedItemHistory.remapPanelAnchorIds(from: entry.snapshot.id, to: panelId)
    }
}
