public import Foundation

/// The per-window seam ``TabManagerClosedItemReopenCoordinator`` drives for the
/// irreducibly-app steps of the per-window recently-closed reopen/restore flows
/// the legacy `TabManager` held inline (`reopenMostRecentlyClosedBrowserPanel`,
/// `reopenMostRecentlyClosedBrowserPanelFromLegacyStack`,
/// `reopenMostRecentlyClosedItem`, `reopenClosedHistoryItem(id:)`, and the two
/// focus-history-suppressed `restoreClosedPanel`/`restoreClosedWorkspace`
/// orderings).
///
/// Everything the coordinator cannot see across the module boundary inverts
/// here: the per-window `TabManager` model (`tabs`/`selectedTabId`,
/// `addWorkspace`/`closeWorkspace`, the `focusedPanelId(for:)` /
/// `selectWorkspaceId` / `rememberFocusedSurface` bookkeeping), the
/// `ClosedItemHistoryStore` singleton (anchor + workspace-id remaps,
/// remove/insert), the `focusHistoryNavigation` suppression and focus-recording
/// API, the legacy `browserModel` recently-closed-browser-panel stack, the
/// `AppDelegate`-routed cross-window entry points, and the AppKit focus
/// re-assertion. The coordinator owns only the *sequence* and routing; the app
/// types never cross into the package.
///
/// **Why opaque history/snapshot tokens.** The store records an app-side
/// `ClosedItemHistoryEntry` (panel / workspace / window) and the legacy
/// browser-panel stack pops an app-side `ClosedBrowserPanelRestoreSnapshot`.
/// The coordinator threads each as an opaque ``HistoryEntry`` /
/// ``BrowserPanelSnapshot`` it never inspects, plus an opaque ``RemovedRecord``
/// carrier (the record + its original store index) for the remove → restore →
/// re-insert sequence, so neither the history-entry enum nor the snapshot's
/// layout crosses the module boundary.
///
/// **Why synchronous and `@MainActor`.** Each reopen/restore is one main-actor
/// turn driven by a menu/shortcut/socket call; the model, the store, the
/// focus-history sub-model, and `NSWindow` focus all live on the main actor, so
/// co-locating the sequence with its callers removes any bridging and preserves
/// the exact ordering of selection, restore, focus-history recording, store
/// remaps, and focus re-assertion that is the observable behavior. This mirrors
/// ``SessionSnapshotRestoreHosting`` and ``WorkspaceCloseHosting``.
@MainActor
public protocol TabManagerClosedItemReopenHosting<HistoryEntry, RemovedRecord, BrowserPanelSnapshot>: AnyObject {
    /// Opaque carrier for an app-side `ClosedItemHistoryEntry` (the
    /// panel / workspace / window history record payload). The coordinator routes
    /// it through ``restoreClosedHistoryEntry(_:)`` without inspecting it.
    associatedtype HistoryEntry

    /// Opaque carrier for a store record the coordinator removed by id and may
    /// re-insert if restoration fails. Wraps the app-target
    /// `ClosedItemHistoryRecord` plus its original index; the coordinator threads
    /// it through the remove → restore → re-insert sequence without inspecting it.
    associatedtype RemovedRecord

    /// Opaque carrier for an app-side `ClosedBrowserPanelRestoreSnapshot` popped
    /// from the legacy recently-closed browser-panel stack. The coordinator
    /// resolves, selects, reopens, and enforces focus for it through the host
    /// without inspecting it.
    associatedtype BrowserPanelSnapshot

    // MARK: AppDelegate cross-window routing

    /// Routes the reopen-most-recent flow to the `AppDelegate` cross-window owner
    /// when one exists, returning whether it reopened an item, or `nil` when there
    /// is no `AppDelegate` (the headless path the coordinator then drives itself).
    /// Lifts the legacy `if let appDelegate = AppDelegate.shared { return
    /// appDelegate.reopenMostRecentlyClosedItem(preferredTabManager: self) }`
    /// guard.
    func reopenMostRecentlyClosedItemViaAppDelegate() -> Bool?

    /// Routes the reopen-by-id flow to the `AppDelegate` cross-window owner when
    /// one exists, returning whether it reopened the item with `id`, or `nil` when
    /// there is no `AppDelegate`. Lifts the legacy `if let appDelegate =
    /// AppDelegate.shared { return appDelegate.reopenClosedHistoryItem(id: id,
    /// preferredTabManager: self) }` guard.
    func reopenClosedHistoryItemViaAppDelegate(id: UUID) -> Bool?

    // MARK: Headless closed-item-history store routing

    /// Restores the first restorable store record (newest first), returning
    /// whether one was restored. Lifts the legacy headless
    /// `ClosedItemHistoryStore.shared.restoreFirstRestorable(using:)` whose
    /// closure switched on the entry type and called the window's
    /// `restoreClosedPanel`/`restoreClosedWorkspace` (and `false` for `.window`);
    /// the host owns the store-iteration + entry-type switch because both reach
    /// app types, and routes each candidate back through
    /// ``restoreClosedHistoryEntry(_:)``.
    func restoreFirstRestorableStoreItem() -> Bool

    /// Removes the store record with `id` and returns it as an opaque
    /// ``RemovedRecord`` carrier (the record plus its original index), or `nil`
    /// when no record matches (legacy `ClosedItemHistoryStore.shared.removeRecord(id:)`).
    func removeStoreRecord(id: UUID) -> RemovedRecord?

    /// The opaque ``HistoryEntry`` payload of a removed store record, so the
    /// coordinator can drive its restore through ``restoreClosedHistoryEntry(_:)``
    /// without inspecting the carrier (legacy `removed.record.entry`).
    func historyEntry(of removed: RemovedRecord) -> HistoryEntry

    /// Restores an opaque closed-item ``HistoryEntry``, returning whether it was
    /// restored. Lifts the legacy entry-type switch: a `.panel` routes to
    /// ``restoreClosedPanel(_:)``'s logic, a `.workspace` to
    /// ``restoreClosedWorkspace(_:)``'s logic, and a `.window` returns `false`.
    /// The host owns the switch because the entry enum and both restore bodies
    /// reach the `Workspace` god type and the closed-item-history singleton.
    func restoreClosedHistoryEntry(_ entry: HistoryEntry) -> Bool

    /// Re-inserts `removed` at its original store index after a failed restore
    /// (legacy `ClosedItemHistoryStore.shared.insert(removed.record, at: removed.index)`).
    func reinsertRemovedRecord(_ removed: RemovedRecord)

    // MARK: Legacy recently-closed browser-panel stack

    /// Whether the browser feature is enabled, gating the entire legacy-stack
    /// reopen (legacy `guard BrowserAvailabilitySettings.isEnabled() else { return false }`).
    var isBrowserEnabled: Bool { get }

    /// Pops the most-recently-closed browser panel off the window's legacy stack
    /// as an opaque ``BrowserPanelSnapshot``, or `nil` when the stack is empty
    /// (legacy `browserModel.popMostRecentlyClosedBrowserPanel()`). The coordinator
    /// drives the pop loop and threads each snapshot back through the host.
    func popMostRecentlyClosedBrowserPanel() -> BrowserPanelSnapshot?

    /// The id of the workspace that originally owned `snapshot`, if it still
    /// exists in this window (legacy `tabs.first(where: { $0.id ==
    /// snapshot.workspaceId })`). `nil` when the owning workspace is gone, so the
    /// coordinator drops the stale snapshot and keeps popping rather than barging
    /// into whatever workspace is selected now.
    func targetWorkspaceId(for snapshot: BrowserPanelSnapshot) -> UUID?

    /// The workspace's currently-focused panel id (legacy
    /// `focusedPanelId(for: targetWorkspace.id)`), captured before the reopen so
    /// the focus re-assertion can tell whether focus later drifted back to it.
    func focusedPanelId(forWorkspaceId workspaceId: UUID) -> UUID?

    /// Whether `workspaceId` is the currently-selected workspace (legacy
    /// `selectedTabId != targetWorkspace.id` test).
    func isSelectedWorkspace(_ workspaceId: UUID) -> Bool

    /// Selects `workspaceId` as part of an explicit workspace-resume (legacy
    /// `selectWorkspaceId(_, notificationDismissalContext: .explicitWorkspaceResume)`),
    /// run only when it is not already selected.
    func selectWorkspaceForResume(_ workspaceId: UUID)

    /// Reopens `snapshot`'s browser panel into the workspace `workspaceId`,
    /// returning the reopened panel id, or `nil` when no panel could be created
    /// (legacy `reopenClosedBrowserPanel(snapshot, in: targetWorkspace)`). The
    /// whole bonsplit pane/split placement is irreducibly app-coupled and stays
    /// app-side.
    func reopenClosedBrowserPanel(
        _ snapshot: BrowserPanelSnapshot,
        inWorkspaceId workspaceId: UUID
    ) -> UUID?

    /// Pins focus to the reopened browser panel and schedules the follow-up
    /// re-assertion turns (legacy `enforceReopenedBrowserFocus(tabId:
    /// reopenedPanelId:preReopenFocusedPanelId:)`), the AppKit focus bookkeeping
    /// that cannot cross the module boundary.
    func enforceReopenedBrowserFocus(
        workspaceId: UUID,
        reopenedPanelId: UUID,
        preReopenFocusedPanelId: UUID?
    )
}
