public import Foundation

/// The per-window app-side seam ``ClosedItemReopenRouting`` drives for the
/// irreducibly-app steps of a single window's recently-closed reopen flows:
/// the `AppDelegate.shared` delegation guard, every reach into the app-target
/// `ClosedItemHistoryStore`, the live `Workspace` lookup plus its closed-panel
/// restore, and the full closed-workspace restore sequence (add the workspace,
/// replay its session snapshot, the empty/has-panels rollback guards, the
/// stale-group drop, the index reinsert, the group-contiguity normalize, and the
/// focus-flash landing). None of those can cross the module boundary
/// (CONVENTIONS §6: an `AppDelegate`/`Workspace`/store reach lives in the
/// executable target), so the coordinator owns the *sequence* and the routing
/// table while inverting each concrete effect here. The window `TabManager` is
/// the single conformer.
///
/// **Why opaque entry/record tokens.** The flows route the app-target
/// `ClosedItemHistoryEntry`/`ClosedPanelHistoryEntry`/`ClosedWorkspaceHistoryEntry`
/// and a removed `(record, index)` pair, none of which the package can name. The
/// host surfaces them as the ``Entry``/``PanelEntry``/``WorkspaceEntry``/
/// ``RemovedRecord`` associated types and maps each entry to a
/// ``ClosedItemReopenRoute`` so the coordinator can switch without inspecting the
/// concrete enum.
///
/// **Why synchronous and `@MainActor`.** Each reopen is one main-actor turn
/// driven by a menu/shortcut/`ContentView` call; the store, the live `Workspace`
/// registry, the selection, and the focus history all live on the main actor, so
/// co-locating removes any bridging and preserves the exact ordering of store
/// mutations, panel restore, selection, and focus-history recording that is the
/// observable behavior. This mirrors ``ClosedItemReopenHosting`` (the
/// cross-window `AppDelegate` flows) at the per-window scope.
@MainActor
public protocol ClosedPanelRestoreHosting<Entry, PanelEntry, WorkspaceEntry, RemovedRecord, RestoredWorkspace>: AnyObject {
    /// Opaque carrier for the app-target `ClosedItemHistoryEntry`. The coordinator
    /// threads it from the store-restore closure / removed record to ``route(for:)``
    /// without inspecting it.
    associatedtype Entry

    /// Opaque carrier for the app-target `ClosedPanelHistoryEntry` a `.panel`
    /// route carries; the coordinator passes it straight back to the panel-restore
    /// witnesses.
    associatedtype PanelEntry

    /// Opaque carrier for the app-target `ClosedWorkspaceHistoryEntry` a
    /// `.workspace` route carries; the coordinator threads it through the
    /// workspace-restore witnesses in
    /// ``ClosedItemReopenRouting/restoreClosedWorkspace(_:)``.
    associatedtype WorkspaceEntry

    /// Opaque carrier for a store record removed by id and re-inserted if its
    /// restore fails (the record plus its original index).
    associatedtype RemovedRecord

    /// Opaque carrier for the live app-target `Workspace` that
    /// ``addRestoredWorkspace(for:)`` creates and the rest of the workspace-restore
    /// sequence threads (panel-replay, the rollback guards, the stale-group drop,
    /// the index reinsert, and the focus-flash landing). The coordinator never
    /// inspects it; it only hands it back to the witnesses below.
    associatedtype RestoredWorkspace

    /// The window's focus-history navigator. The coordinator owns the
    /// suppression ordering of the panel-restore flow and records landings
    /// through this; the host exposes the same instance it mutates elsewhere so
    /// recording stays a single source of truth.
    var focusHistory: any FocusHistoryNavigating { get }

    /// Stable workspace/panel identities already live in this window. Restore
    /// paths use this to avoid duplicating a still-live surface identity when a
    /// closed item snapshot is replayed.
    func liveStableIdentitySet() -> Set<UUID>

    // MARK: AppDelegate delegation guards

    /// When a composition-root `AppDelegate` exists, routes the reopen-most-recent
    /// flow to its cross-window coordinator (preferring this window) and returns
    /// that result; `nil` when no `AppDelegate` is present, so the coordinator
    /// runs the per-window flow (legacy
    /// `if let appDelegate = AppDelegate.shared { return appDelegate.reopenMostRecentlyClosedItem(preferredTabManager: self) }`).
    func reopenMostRecentlyClosedItemViaAppDelegate() -> Bool?

    /// The reopen-by-id analogue of ``reopenMostRecentlyClosedItemViaAppDelegate()``
    /// (legacy `appDelegate.reopenClosedHistoryItem(id:preferredTabManager:)`).
    func reopenClosedHistoryItemViaAppDelegate(id: UUID) -> Bool?

    // MARK: Store reads / mutations

    /// Attempts the store's first restorable record using `restore`, returning
    /// whether one was restored (legacy
    /// `closedItemHistory.restoreFirstRestorable(using:)`). The coordinator passes
    /// its own per-entry routing closure.
    func restoreFirstRestorable(using restore: (Entry) -> Bool) -> Bool

    /// Removes the store record with `id`, returning it as an opaque
    /// ``RemovedRecord`` (record plus original index), or `nil` when unknown
    /// (legacy `closedItemHistory.removeRecord(id:)`).
    func removeRecord(id: UUID) -> RemovedRecord?

    /// The history entry carried by `removed` (legacy `removed.record.entry`).
    func entry(of removed: RemovedRecord) -> Entry

    /// Re-inserts `removed` at its original store index after a failed restore
    /// (legacy `closedItemHistory.insert(removed.record, at: removed.index)`).
    func reinsertRemovedRecord(_ removed: RemovedRecord)

    // MARK: Entry routing

    /// Maps `entry` to the per-window ``ClosedItemReopenRoute`` so the coordinator
    /// can switch without naming the app enum (legacy `switch entry { case .panel … }`).
    func route(for entry: Entry) -> ClosedItemReopenRoute<PanelEntry, WorkspaceEntry>

    // MARK: Workspace-restore witnesses

    /// Whether `entry`'s snapshot declares any restorable panels (legacy
    /// `entry.snapshot.hasRestorablePanels`). Used by the first rollback guard.
    func snapshotHasRestorablePanels(_ entry: WorkspaceEntry) -> Bool

    /// The snapshot's original workspace id (legacy `entry.workspaceId`), the
    /// `from:` of the panel-workspace-id remap.
    func entryWorkspaceId(_ entry: WorkspaceEntry) -> UUID

    /// The snapshot's original absolute workspace index (legacy
    /// `entry.workspaceIndex`), where the restored workspace is reinserted.
    func entryWorkspaceIndex(_ entry: WorkspaceEntry) -> Int

    /// Adds a fresh workspace seeded from `entry`'s snapshot (title, working
    /// directory) without selecting it or auto-welcoming, returning it as the
    /// opaque ``RestoredWorkspace`` the rest of the flow threads (legacy
    /// `addWorkspace(title:workingDirectory:select:false,autoWelcomeIfNeeded:false)`).
    func addRestoredWorkspace(for entry: WorkspaceEntry) -> RestoredWorkspace

    /// Replays `entry`'s session snapshot into `workspace`, returning the
    /// old-to-new panel id map.
    func restoreSessionSnapshot(
        _ entry: WorkspaceEntry,
        into workspace: RestoredWorkspace,
        excludingStableIdentities: Set<UUID>
    ) -> [UUID: UUID]

    /// Closes `workspace` without recording close history, the rollback both
    /// has-panels guards run (legacy `closeWorkspace(workspace, recordHistory: false)`).
    func closeRestoredWorkspace(_ workspace: RestoredWorkspace)

    /// Whether `workspace` ended up with no live panels (legacy
    /// `workspace.panels.isEmpty`). Drives the second rollback guard.
    func restoredWorkspaceHasNoPanels(_ workspace: RestoredWorkspace) -> Bool

    /// The id of the live restored `workspace` (legacy `workspace.id`), threaded
    /// into the remap target, the index reinsert, the selection, and the
    /// focus-history landing.
    func restoredWorkspaceId(_ workspace: RestoredWorkspace) -> UUID

    /// `workspace`'s current group id, or `nil` when ungrouped (legacy
    /// `workspace.groupId`). Read for the stale-group drop and the normalize decision.
    func restoredWorkspaceGroupId(_ workspace: RestoredWorkspace) -> UUID?

    /// Clears `workspace`'s group id (legacy `workspace.groupId = nil`) when its
    /// snapshot group no longer exists in this window.
    func clearRestoredWorkspaceGroupId(_ workspace: RestoredWorkspace)

    /// `workspace`'s focused panel id, or `nil` (legacy `workspace.focusedPanelId`).
    /// Selects the focus-flash branch of the landing.
    func restoredWorkspaceFocusedPanelId(_ workspace: RestoredWorkspace) -> UUID?

    /// Whether a group with `id` still exists in this window (legacy
    /// `workspaceGroups.contains(where: { $0.id == groupId })`).
    func hasWorkspaceGroup(id: UUID) -> Bool

    /// Whether this window has any workspace groups at all (legacy
    /// `!workspaceGroups.isEmpty`). Part of the normalize decision.
    func hasAnyWorkspaceGroups() -> Bool

    /// Remaps the store's panel-workspace ids from `oldWorkspaceId` to
    /// `newWorkspaceId` using `panelIdMap` (legacy
    /// `closedItemHistory.remapPanelWorkspaceIds(from:to:panelIdMap:)`).
    func remapPanelWorkspaceIds(from oldWorkspaceId: UUID, to newWorkspaceId: UUID, panelIdMap: [UUID: UUID])

    /// Reinserts the restored workspace `id` at its clamped original
    /// `workspaceIndex` in the tab order (legacy
    /// `tabs.firstIndex … remove … insert(at: min(max(index,0), tabs.count))`).
    func reinsertRestoredWorkspace(id workspaceId: UUID, atIndex workspaceIndex: Int)

    /// Renormalizes group contiguity after a grouped restore (legacy
    /// `workspaces.normalizeWorkspaceGroupContiguity()`).
    func normalizeWorkspaceGroupContiguity()

    /// Flashes `panelId` in `workspace` so the user can confirm focus (legacy
    /// `workspace.triggerFocusFlash(panelId:)`).
    func triggerFocusFlash(_ workspace: RestoredWorkspace, panelId: UUID)

    // MARK: Panel-restore witnesses

    /// The id of the live workspace that hosts `entry`'s panel, or `nil` when it
    /// is gone (legacy `tabs.first(where: { $0.id == entry.workspaceId })`,
    /// surfaced as the workspace id the rest of the flow threads).
    func panelRestoreWorkspaceId(for entry: PanelEntry) -> UUID?

    /// Restores `entry`'s panel into its workspace, returning the new panel id;
    /// `nil` when the workspace is gone or the restore declines. The coordinator
    /// wraps this call in focus-history suppression.
    func restoreClosedPanelInWorkspace(
        _ entry: PanelEntry,
        excludingStableIdentities: Set<UUID>
    ) -> UUID?

    /// Remaps the store's panel-anchor ids from `entry`'s snapshot id to the
    /// newly restored `panelId` (legacy
    /// `closedItemHistory.remapPanelAnchorIds(from: entry.snapshot.id, to: panelId)`).
    func remapPanelAnchorIds(for entry: PanelEntry, to panelId: UUID)

    /// Selects `workspaceId` when it is not already selected (legacy
    /// `if selectedTabId != workspace.id { selectedTabId = workspace.id }`). The
    /// coordinator wraps this in focus-history suppression. Shared with
    /// ``FocusHistoryHosting``.
    func selectWorkspace(_ workspaceId: UUID)

    /// Remembers `surfaceId` as the focused surface for `workspaceId` (legacy
    /// `rememberFocusedSurface(tabId:surfaceId:)`). Shared with
    /// ``FocusHistoryHosting``.
    func rememberFocusedSurface(workspaceId: UUID, surfaceId: UUID)
}

public extension ClosedPanelRestoreHosting {
    func liveStableIdentitySet() -> Set<UUID> {
        []
    }
}
