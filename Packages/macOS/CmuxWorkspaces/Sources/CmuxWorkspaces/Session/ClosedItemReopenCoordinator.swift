public import Foundation

/// Owns the cross-window recently-closed-history reopen/clear *routing* — the
/// control flow the legacy `AppDelegate+ClosedItemHistory` extension held — and
/// inverts every concrete reach (the closed-item history store, the per-window
/// `TabManager` registry and its legacy browser-panel stack, window
/// creation/discard, focus) through ``ClosedItemReopenHosting``.
///
/// **What the coordinator owns vs. inverts.** The coordinator owns the *sequence*
/// that is independent of the app types: the clear flow's manager dedupe, the
/// reopen-most-recent flow's interleave of store restores and legacy
/// browser-stack pops together with the running failed-record exclusion set, and
/// the reopen-by-id flow's remove → restore → re-insert-on-failure bookkeeping.
/// Every operation that reads or mutates the store, walks the live registry,
/// restores an entry, creates/discards a window, or activates focus inverts
/// through the host. The store and the entry types stay app-side; the host
/// threads opaque ``ClosedItemReopenHosting/Manager`` and
/// ``ClosedItemReopenHosting/RemovedRecord`` tokens.
///
/// **Why `@MainActor`, synchronous, app-owned.** Each flow is one main-actor turn
/// driven by a menu/shortcut/socket call, reaching state (store, registry,
/// `NSWindow` focus) that all lives on the main actor. The flows are app-global
/// (they span every window), so `AppDelegate` — the composition root — owns the
/// coordinator and conforms to the host, mirroring
/// ``WorkspaceCreationActionCoordinator``. Co-locating the sequence with its
/// callers removes any bridging and preserves the exact ordering of store
/// mutations, window creation, and focus that is the observable behavior.
@MainActor
public final class ClosedItemReopenCoordinator<Host: ClosedItemReopenHosting> {
    private let host: Host

    /// Creates the coordinator over its app-side host.
    public init(host: Host) {
        self.host = host
    }

    /// Clears all recently-closed history: removes every store record, then wipes
    /// the legacy recently-closed browser-panel history of the preferred manager,
    /// the root manager, every registered main window, and every recoverable
    /// route, each at most once. Lifts the legacy
    /// `AppDelegate.clearRecentlyClosedHistory(preferredTabManager:)` one-for-one;
    /// the host returns the manager list (with duplicates) in the legacy order and
    /// the coordinator dedupes by ``ClosedItemReopenHosting/Manager`` identity,
    /// reproducing the legacy `clearedManagers` guard.
    public func clearRecentlyClosedHistory(preferred: Host.Manager? = nil) {
        host.removeAllClosedItemHistory()

        var clearedManagers: Set<Host.Manager> = []
        for manager in host.managersForClear(preferred: preferred) {
            guard clearedManagers.insert(manager).inserted else { continue }
            host.clearRecentlyClosedBrowserPanelHistory(manager)
        }
    }

    /// Reopens the single most-recently-closed item across all windows, returning
    /// whether one was reopened. Lifts the legacy
    /// `AppDelegate.reopenMostRecentlyClosedItem(preferredTabManager:shouldActivate:)`
    /// one-for-one: for each manager holding legacy closed browser panels (newest
    /// first), first try the store newer than that manager's most-recent
    /// browser-close timestamp, then that manager's legacy browser stack; finally
    /// try the store with no cutoff. The failed-record exclusion set accumulates
    /// across the interleaved attempts so a record that failed restoration is
    /// never retried within the flow (legacy `failedStoreRecordIds`).
    @discardableResult
    public func reopenMostRecentlyClosedItem(
        preferred: Host.Manager? = nil,
        shouldActivate: Bool = true
    ) -> Bool {
        var failedStoreRecordIds: Set<UUID> = []
        func restoreStoreItem(_ cutoff: Date?) -> Bool {
            let outcome = host.restoreFirstRestorableStoreItem(
                newerThan: cutoff,
                excluding: failedStoreRecordIds,
                preferred: preferred,
                shouldActivate: shouldActivate
            )
            failedStoreRecordIds.formUnion(outcome.failedRecordIds)
            return outcome.didRestore
        }

        for manager in host.recentlyClosedLegacyBrowserManagers(preferred: preferred) {
            guard let closedAt = host.mostRecentLegacyClosedBrowserPanelClosedAt(manager) else {
                continue
            }
            if restoreStoreItem(closedAt) {
                return true
            }
            if host.reopenMostRecentlyClosedBrowserPanelFromLegacyStack(manager) {
                return true
            }
        }

        return restoreStoreItem(nil)
    }

    /// Reopens the closed-history item with `id`, returning whether it was
    /// reopened. Lifts the legacy
    /// `AppDelegate.reopenClosedHistoryItem(id:preferredTabManager:shouldActivate:)`
    /// one-for-one: remove the record, restore it, and on failure re-insert it at
    /// its original index. A no-op `false` when the id is unknown.
    @discardableResult
    public func reopenClosedHistoryItem(
        id: UUID,
        preferred: Host.Manager? = nil,
        shouldActivate: Bool = true
    ) -> Bool {
        guard let removed = host.removeStoreRecord(id: id) else {
            return false
        }

        if host.restoreRemovedRecord(
            removed,
            preferred: preferred,
            shouldActivate: shouldActivate
        ) {
            return true
        }

        host.reinsertRemovedRecord(removed)
        return false
    }
}
