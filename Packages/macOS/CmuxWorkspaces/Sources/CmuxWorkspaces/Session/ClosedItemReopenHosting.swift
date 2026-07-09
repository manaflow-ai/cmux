public import Foundation

/// The app-side seam ``ClosedItemReopenCoordinator`` drives for the
/// irreducibly-app steps of the recently-closed-history reopen/clear flows:
/// every reach into the app-target `ClosedItemHistoryStore` singleton, the
/// per-window `TabManager` registry and its legacy recently-closed browser-panel
/// stack, the `createMainWindow`/`discardMainWindowWithoutClosedHistory` window
/// lifecycle, and the focus activation. None of those can cross the module
/// boundary (CONVENTIONS §6: an `AppDelegate`/`NSWindow` reach lives in the
/// executable target), so the coordinator owns the *sequence* and inverts each
/// concrete effect here. `AppDelegate` is the single conformer.
///
/// **Why an opaque `Manager` token.** The reopen flows walk the live `TabManager`
/// registry (the preferred manager, the root manager, every registered main
/// window, every recoverable route) deduplicated by object identity and ordered
/// by each manager's most-recent legacy-closed-browser timestamp. The package
/// never inspects a `TabManager`; it only needs to thread opaque, identity-stable
/// handles back to the host. The host surfaces each manager as a `Manager`
/// associated type (the app target's `TabManagerToken`, which wraps the live
/// manager and hashes by `ObjectIdentifier`), so the coordinator can dedupe and
/// order while the host performs every manager operation.
///
/// **Why synchronous and `@MainActor`.** Each reopen/clear is one main-actor
/// turn driven by a menu/shortcut/socket call; the store, the registry, and the
/// window lifecycle all live on the main actor, so co-locating removes any
/// bridging and preserves the exact ordering of store mutations, window
/// creation, and focus that is the observable behavior. This mirrors
/// ``SessionSnapshotRestoreHosting`` and ``WorkspaceCloseHosting``.
@MainActor
public protocol ClosedItemReopenHosting<Manager, RemovedRecord>: AnyObject {
    /// Opaque, identity-stable handle for a live per-window `TabManager`. The app
    /// target's wrapper hashes by `ObjectIdentifier` so the coordinator's dedupe
    /// (`Set<Manager>`) matches the legacy `Set<ObjectIdentifier>` exactly.
    associatedtype Manager: Hashable

    /// Opaque carrier for a store record the coordinator removed by id and may
    /// re-insert if restoration fails. Wraps the app-target
    /// `ClosedItemHistoryRecord` plus its original index; the coordinator threads
    /// it through the remove → restore → re-insert sequence without inspecting it.
    associatedtype RemovedRecord

    // MARK: Clear flow (legacy clearRecentlyClosedHistory)

    /// Removes every record from the closed-item history store (legacy
    /// `closedItemHistory.removeAll()`).
    func removeAllClosedItemHistory()

    /// The managers whose recently-closed browser-panel history the clear flow
    /// must also wipe, in the legacy order: the preferred manager, the root
    /// manager, every registered main window's manager, then every recoverable
    /// route's manager. The host returns them with duplicates still present; the
    /// coordinator dedupes by `Manager` identity, reproducing the legacy
    /// `clearedManagers` guard. `nil` entries (an absent manager) are pre-filtered
    /// by the host.
    func managersForClear(preferred: Manager?) -> [Manager]

    /// Clears `manager`'s legacy recently-closed browser-panel history (legacy
    /// `manager.clearRecentlyClosedBrowserPanelHistory()`).
    func clearRecentlyClosedBrowserPanelHistory(_ manager: Manager)

    // MARK: Reopen-most-recent flow (legacy reopenMostRecentlyClosedItem)

    /// The managers that currently hold legacy recently-closed browser panels,
    /// already deduplicated by identity and sorted newest-first by each manager's
    /// most-recent legacy-closed-browser timestamp (legacy
    /// `recentlyClosedLegacyBrowserManagers(preferredTabManager:)`). The host owns
    /// the build because it reads the live registry and each manager's timestamp;
    /// the coordinator only iterates the result.
    func recentlyClosedLegacyBrowserManagers(preferred: Manager?) -> [Manager]

    /// `manager`'s most-recent legacy-closed-browser timestamp, used as the
    /// store-restore cutoff for that manager's turn in the interleave (legacy
    /// `manager.mostRecentLegacyClosedBrowserPanelClosedAt()`). `nil` when the
    /// manager no longer has one (the coordinator skips it, matching the legacy
    /// `guard let closedAt … else { continue }`).
    func mostRecentLegacyClosedBrowserPanelClosedAt(_ manager: Manager) -> Date?

    /// Attempts to restore the first restorable store record newer than `cutoff`
    /// (all records when `cutoff` is `nil`), skipping `excluding`, activating the
    /// restored window when `shouldActivate`, and preferring `preferred` for
    /// ambiguous panel/workspace routing (legacy
    /// `closedItemHistory.restoreFirstRestorable(newerThan:excluding:onFailure:using:)`
    /// driving `restoreClosedItem`). Returns whether a record was restored plus
    /// the ids the store attempted and rejected, which the coordinator accumulates
    /// into the running exclusion set.
    func restoreFirstRestorableStoreItem(
        newerThan cutoff: Date?,
        excluding: Set<UUID>,
        preferred: Manager?,
        shouldActivate: Bool
    ) -> ClosedItemReopenStoreRestoreOutcome

    /// Reopens `manager`'s most-recently-closed browser panel from its legacy
    /// stack, returning whether one was reopened (legacy
    /// `manager.reopenMostRecentlyClosedBrowserPanelFromLegacyStack()`).
    func reopenMostRecentlyClosedBrowserPanelFromLegacyStack(_ manager: Manager) -> Bool

    // MARK: Reopen-by-id flow (legacy reopenClosedHistoryItem)

    /// Removes the store record with `id` and returns it as an opaque
    /// ``RemovedRecord`` carrier (the record plus its original index), or `nil`
    /// when no record matches (legacy `closedItemHistory.removeRecord(id:)`).
    func removeStoreRecord(id: UUID) -> RemovedRecord?

    /// Restores `removed`'s entry, preferring `preferred` and activating when
    /// `shouldActivate` (legacy `restoreClosedItem(removed.record.entry, …)`).
    /// Returns whether the entry was restored.
    func restoreRemovedRecord(
        _ removed: RemovedRecord,
        preferred: Manager?,
        shouldActivate: Bool
    ) -> Bool

    /// Re-inserts `removed` at its original index after a failed restore (legacy
    /// `closedItemHistory.insert(removed.record, at: removed.index)`).
    func reinsertRemovedRecord(_ removed: RemovedRecord)
}
