public import Foundation

/// Owns the per-window recently-closed reopen *routing* — the control flow the
/// legacy window-god `TabManager` held in `reopenMostRecentlyClosedItem()`,
/// `reopenClosedHistoryItem(id:)`, and `restoreClosedPanel(_:)` — and inverts
/// every concrete reach (the `AppDelegate.shared` delegation, the closed-item
/// history store, the live `Workspace` lookup and restore, the selection) through
/// ``ClosedPanelRestoreHosting``.
///
/// **What the coordinator owns vs. inverts.** The coordinator owns the *sequence*
/// independent of the app types: the `AppDelegate` delegation guard each flow
/// opens with, the per-entry routing table (panel → ``restoreClosedPanel(_:)``,
/// workspace → ``restoreClosedWorkspace(_:)``, window → `false`), the
/// reopen-by-id remove → restore → re-insert-on-failure bookkeeping, and the
/// focus-history suppression ordering of the panel restore (capture pre-restore
/// focus, restore suppressed, remap anchors, select suppressed, record the
/// pre-restore landing, remember the surface, record the restored landing). Every
/// store read/mutation, `Workspace` lookup/restore, and selection inverts through
/// the host; the entry/record types stay app-side as opaque tokens.
///
/// **Why `@MainActor`, synchronous, per-window-owned.** Each flow is one
/// main-actor turn driven by a menu/shortcut/`ContentView` call, reaching state
/// (store, live workspaces, selection, focus history) that all lives on the main
/// actor. The flows are per-window, so the window `TabManager` owns the
/// coordinator and conforms to the host, mirroring the cross-window
/// ``ClosedItemReopenCoordinator`` at the per-window scope. Co-locating the
/// sequence with its callers removes any bridging and preserves the exact
/// ordering of store mutations, panel restore, selection, and focus recording
/// that is the observable behavior.
@MainActor
public final class ClosedItemReopenRouting<Host: ClosedPanelRestoreHosting> {
    private let host: Host

    /// Creates the coordinator over its per-window app-side host.
    public init(host: Host) {
        self.host = host
    }

    /// Reopens the most recently closed item for this window, returning whether
    /// one was reopened. Lifts the legacy `TabManager.reopenMostRecentlyClosedItem()`
    /// one-for-one: when an `AppDelegate` exists the cross-window coordinator
    /// handles it; otherwise the store's first restorable record is routed by kind.
    @discardableResult
    public func reopenMostRecentlyClosedItem() -> Bool {
        if let delegated = host.reopenMostRecentlyClosedItemViaAppDelegate() {
            return delegated
        }

        if host.restoreFirstRestorable(using: { entry in self.restore(entry) }) {
            return true
        }

        return false
    }

    /// Reopens the closed-history item with `id` for this window, returning
    /// whether it was reopened. Lifts the legacy
    /// `TabManager.reopenClosedHistoryItem(id:)` one-for-one: delegate to the
    /// `AppDelegate` flow when present, otherwise remove the record, route it by
    /// kind, and re-insert it at its original index on a failed restore. A no-op
    /// `false` when the id is unknown.
    @discardableResult
    public func reopenClosedHistoryItem(id: UUID) -> Bool {
        if let delegated = host.reopenClosedHistoryItemViaAppDelegate(id: id) {
            return delegated
        }

        guard let removed = host.removeRecord(id: id) else {
            return false
        }

        let didRestore = restore(host.entry(of: removed))
        if !didRestore {
            host.reinsertRemovedRecord(removed)
        }
        return didRestore
    }

    /// The per-entry routing table shared by both reopen flows: panel entries run
    /// the coordinator's own focus-ordering restore, workspace entries run the
    /// coordinator's own ``restoreClosedWorkspace(_:)``, and window entries are
    /// never restorable here (legacy `switch entry { … case .window: return false }`).
    private func restore(_ entry: Host.Entry) -> Bool {
        switch host.route(for: entry) {
        case .panel(let panelEntry):
            return restoreClosedPanel(panelEntry)
        case .workspace(let workspaceEntry):
            return restoreClosedWorkspace(workspaceEntry)
        case .window:
            return false
        }
    }

    /// Restores a closed workspace from `entry` and records its focus-history
    /// landing, returning whether it was restored. Lifts the legacy
    /// `TabManager.restoreClosedWorkspace(_:)` one-for-one: capture the pre-restore
    /// focus, add a fresh workspace seeded from the snapshot, replay the session
    /// snapshot, roll back (close, no history) when the snapshot promised panels
    /// but none came back or the workspace is empty, drop a stale group id, decide
    /// whether a group normalize is needed, remap the store's panel-workspace ids,
    /// reinsert the workspace at its original index, normalize group contiguity
    /// when grouped, then select with recording suppressed and record the landing
    /// (flashing the focused panel when present). Every concrete reach inverts
    /// through ``ClosedPanelRestoreHosting``.
    @discardableResult
    public func restoreClosedWorkspace(_ entry: Host.WorkspaceEntry) -> Bool {
        let preRestoreFocus = host.focusHistory.currentFocusHistoryEntry
        let workspace = host.addRestoredWorkspace(for: entry)
        let restoredPanelIds = host.restoreSessionSnapshot(
            entry,
            into: workspace,
            excludingStableIdentities: host.liveStableIdentitySet()
        )
        guard !host.snapshotHasRestorablePanels(entry) || !restoredPanelIds.isEmpty else {
            host.closeRestoredWorkspace(workspace)
            return false
        }
        guard !host.restoredWorkspaceHasNoPanels(workspace) else {
            host.closeRestoredWorkspace(workspace)
            return false
        }
        // The snapshot may carry a groupId for a group that no longer exists
        // in this window (e.g. the group was dissolved between close and
        // reopen). Drop those stale references so the restored workspace
        // doesn't render as an orphaned indented row under no header.
        if let groupId = host.restoredWorkspaceGroupId(workspace),
           !host.hasWorkspaceGroup(id: groupId) {
            host.clearRestoredWorkspaceGroupId(workspace)
        }
        // When the group DOES still exist, the workspace is about to be
        // reinserted at its old absolute index, which may now sit inside a
        // different group section after intervening reorders. Renormalize
        // so the restored member lands beside its group.
        let needsNormalize = host.restoredWorkspaceGroupId(workspace) != nil && host.hasAnyWorkspaceGroups()
        let workspaceId = host.restoredWorkspaceId(workspace)
        host.remapPanelWorkspaceIds(
            from: host.entryWorkspaceId(entry),
            to: workspaceId,
            panelIdMap: restoredPanelIds
        )

        host.reinsertRestoredWorkspace(id: workspaceId, atIndex: host.entryWorkspaceIndex(entry))
        if needsNormalize {
            host.normalizeWorkspaceGroupContiguity()
        }

        host.focusHistory.withFocusHistoryRecordingSuppressed {
            host.selectWorkspace(workspaceId)
        }
        host.focusHistory.recordFocusInHistory(preRestoreFocus, preservingForwardBranch: true)
        if let focusedPanelId = host.restoredWorkspaceFocusedPanelId(workspace) {
            host.rememberFocusedSurface(workspaceId: workspaceId, surfaceId: focusedPanelId)
            host.triggerFocusFlash(workspace, panelId: focusedPanelId)
            host.focusHistory.recordFocusInHistory(
                workspaceId: workspaceId,
                panelId: focusedPanelId,
                preservingForwardBranch: true
            )
        } else {
            host.focusHistory.recordFocusInHistory(
                workspaceId: workspaceId,
                panelId: nil,
                preservingForwardBranch: true
            )
        }
        return true
    }

    /// Restores a closed panel into its workspace and records the focus-history
    /// landings, returning whether it was restored. Lifts the legacy
    /// `TabManager.restoreClosedPanel(_:)` one-for-one: guard the live workspace,
    /// capture the pre-restore focus, restore the panel with recording suppressed,
    /// remap the store's panel anchors, select the workspace with recording
    /// suppressed, then record the pre-restore landing, remember the surface, and
    /// record the restored landing (both preserving the forward branch).
    @discardableResult
    public func restoreClosedPanel(_ entry: Host.PanelEntry) -> Bool {
        guard let workspaceId = host.panelRestoreWorkspaceId(for: entry) else {
            return false
        }

        let preRestoreFocus = host.focusHistory.currentFocusHistoryEntry
        let panelId = host.focusHistory.withFocusHistoryRecordingSuppressed {
            host.restoreClosedPanelInWorkspace(
                entry,
                excludingStableIdentities: host.liveStableIdentitySet()
            )
        }

        guard let panelId else { return false }
        host.remapPanelAnchorIds(for: entry, to: panelId)
        host.focusHistory.withFocusHistoryRecordingSuppressed {
            host.selectWorkspace(workspaceId)
        }
        host.focusHistory.recordFocusInHistory(preRestoreFocus, preservingForwardBranch: true)
        host.rememberFocusedSurface(workspaceId: workspaceId, surfaceId: panelId)
        host.focusHistory.recordFocusInHistory(
            workspaceId: workspaceId,
            panelId: panelId,
            preservingForwardBranch: true
        )
        return true
    }
}
