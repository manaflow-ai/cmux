public import Foundation

/// The per-window app-side seam ``ClosedItemReopenRouting`` drives for the
/// irreducibly-app steps of a single window's recently-closed reopen flows:
/// the `AppDelegate.shared` delegation guard, every reach into the app-target
/// `ClosedItemHistoryStore`, the live `Workspace` lookup plus its closed-panel
/// restore, and the closed-workspace restore that still lives on the window god
/// (`restoreClosedWorkspace`). None of those can cross the module boundary
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
public protocol ClosedPanelRestoreHosting<Entry, PanelEntry, WorkspaceEntry, RemovedRecord>: AnyObject {
    /// Opaque carrier for the app-target `ClosedItemHistoryEntry`. The coordinator
    /// threads it from the store-restore closure / removed record to ``route(for:)``
    /// without inspecting it.
    associatedtype Entry

    /// Opaque carrier for the app-target `ClosedPanelHistoryEntry` a `.panel`
    /// route carries; the coordinator passes it straight back to the panel-restore
    /// witnesses.
    associatedtype PanelEntry

    /// Opaque carrier for the app-target `ClosedWorkspaceHistoryEntry` a
    /// `.workspace` route carries; the coordinator forwards it to
    /// ``restoreClosedWorkspace(_:)``.
    associatedtype WorkspaceEntry

    /// Opaque carrier for a store record removed by id and re-inserted if its
    /// restore fails (the record plus its original index).
    associatedtype RemovedRecord

    /// The window's focus-history navigator. The coordinator owns the
    /// suppression ordering of the panel-restore flow and records landings
    /// through this; the host exposes the same instance it mutates elsewhere so
    /// recording stays a single source of truth.
    var focusHistory: any FocusHistoryNavigating { get }

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

    /// Restores a closed workspace entry, returning whether it was restored
    /// (legacy `restoreClosedWorkspace(workspaceEntry)`, still owned by the window
    /// god). Reached only for the `.workspace` route.
    func restoreClosedWorkspace(_ entry: WorkspaceEntry) -> Bool

    // MARK: Panel-restore witnesses

    /// The id of the live workspace that hosts `entry`'s panel, or `nil` when it
    /// is gone (legacy `tabs.first(where: { $0.id == entry.workspaceId })`,
    /// surfaced as the workspace id the rest of the flow threads).
    func panelRestoreWorkspaceId(for entry: PanelEntry) -> UUID?

    /// Restores `entry`'s panel into its workspace, returning the new panel id
    /// (legacy `workspace.restoreClosedPanel(entry)`); `nil` when the workspace is
    /// gone or the restore declines. The coordinator wraps this call in
    /// focus-history suppression.
    func restoreClosedPanelInWorkspace(_ entry: PanelEntry) -> UUID?

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
