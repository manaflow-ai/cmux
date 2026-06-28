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
/// workspace → the host's `restoreClosedWorkspace`, window → `false`), the
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
    /// the coordinator's own focus-ordering restore, workspace entries forward to
    /// the host's `restoreClosedWorkspace`, and window entries are never
    /// restorable here (legacy `switch entry { … case .window: return false }`).
    private func restore(_ entry: Host.Entry) -> Bool {
        switch host.route(for: entry) {
        case .panel(let panelEntry):
            return restoreClosedPanel(panelEntry)
        case .workspace(let workspaceEntry):
            return host.restoreClosedWorkspace(workspaceEntry)
        case .window:
            return false
        }
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
            host.restoreClosedPanelInWorkspace(entry)
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
