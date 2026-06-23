public import Foundation
import Observation

/// Per-window coordinator that owns the *ordering* of the per-window
/// recently-closed reopen/restore flows, draining the orchestration the legacy
/// `TabManager` kept inline across `reopenMostRecentlyClosedBrowserPanel`,
/// `reopenMostRecentlyClosedBrowserPanelFromLegacyStack`,
/// `reopenMostRecentlyClosedItem`, and `reopenClosedHistoryItem(id:)`.
///
/// The coordinator owns the control flow that is independent of the app types:
///
/// 1. **reopen-most-recent → legacy-stack fallthrough.** Try the closed-item
///    store first; only if it reopens nothing, fall through to this window's
///    legacy recently-closed browser-panel stack.
/// 2. **headless store-restore routing.** When there is no `AppDelegate`
///    cross-window owner, drive the store's first-restorable restore itself
///    (the host owns the store iteration + entry-type switch because both reach
///    app types).
/// 3. **legacy-stack pop loop.** Pop newest-first; for each popped snapshot
///    resolve its owning workspace (skip + keep popping when it is gone),
///    capture the pre-reopen focus, select the workspace when it is not already
///    selected, reopen the panel, and on success pin/enforce its focus and stop.
/// 4. **reopen-by-id bookkeeping.** Remove the record by id, restore it, and on
///    failure re-insert it at its original store index.
///
/// Every reach into the app types (the `TabManager` model, the
/// `ClosedItemHistoryStore` singleton, the `focusHistoryNavigation`
/// suppression/recording API, the legacy `browserModel` stack, the
/// `AppDelegate` cross-window routing, and the AppKit focus re-assertion)
/// inverts through ``TabManagerClosedItemReopenHosting``. The store's
/// history-entry enum and the browser-panel snapshot are opaque associated
/// types the coordinator threads but never inspects.
///
/// **Isolation design.** `@MainActor` because every flow is one main-actor turn
/// over live per-window state (model, store, focus-history sub-model, `NSWindow`
/// focus) and the host is called synchronously, exactly as the legacy inline
/// bodies ran; a private actor would open suspension windows between the
/// select/reopen/enforce steps and observably change the focus ordering this
/// coordinator exists to preserve. `@Observable` (not `ObservableObject`) per
/// the refactor migration target, though this stage exposes no observed state.
@MainActor
@Observable
public final class TabManagerClosedItemReopenCoordinator<Host: TabManagerClosedItemReopenHosting> {
    @ObservationIgnored
    private weak var host: Host?

    /// Creates the coordinator. The host attaches separately so the app can
    /// construct the coordinator before the `TabManager` wiring is live,
    /// mirroring the other `CmuxWorkspaces` coordinators.
    public init() {}

    /// Attaches the per-window host. Call before any reopen turn.
    public func attach(host: Host) {
        self.host = host
    }

    // MARK: - Browser-panel reopen entry points

    /// Reopens the most recently closed browser panel (Cmd+Shift+T): try the
    /// closed-item store first, then fall through to this window's legacy
    /// recently-closed browser-panel stack. Lifts the legacy
    /// `reopenMostRecentlyClosedBrowserPanel` one-for-one.
    @discardableResult
    public func reopenMostRecentlyClosedBrowserPanel() -> Bool {
        if reopenMostRecentlyClosedItem() {
            return true
        }

        return reopenMostRecentlyClosedBrowserPanelFromLegacyStack()
    }

    /// Reopens this window's most-recently-closed browser panel from its legacy
    /// stack, returning whether one was reopened. Lifts the legacy
    /// `reopenMostRecentlyClosedBrowserPanelFromLegacyStack` pop loop one-for-one:
    /// pop newest-first; a popped snapshot whose owning workspace is gone is stale
    /// and dropped (keep popping) rather than barging into whatever workspace is
    /// selected now; otherwise capture the pre-reopen focus, select the owning
    /// workspace when it is not already selected, reopen the panel, and on success
    /// enforce its focus and return.
    @discardableResult
    public func reopenMostRecentlyClosedBrowserPanelFromLegacyStack() -> Bool {
        guard let host else { return false }
        guard host.isBrowserEnabled else { return false }

        while let snapshot = host.popMostRecentlyClosedBrowserPanel() {
            // The legacy stack must restore into the workspace that originally
            // owned the browser. If that workspace is gone, the snapshot is stale
            // and we drop it instead of barging into whatever workspace happens to
            // be selected now (which surfaced yesterday's browser inside today's
            // unrelated workspaces).
            guard let targetWorkspaceId = host.targetWorkspaceId(for: snapshot) else {
                continue
            }
            let preReopenFocusedPanelId = host.focusedPanelId(forWorkspaceId: targetWorkspaceId)

            if !host.isSelectedWorkspace(targetWorkspaceId) {
                host.selectWorkspaceForResume(targetWorkspaceId)
            }

            if let reopenedPanelId = host.reopenClosedBrowserPanel(
                snapshot,
                inWorkspaceId: targetWorkspaceId
            ) {
                host.enforceReopenedBrowserFocus(
                    workspaceId: targetWorkspaceId,
                    reopenedPanelId: reopenedPanelId,
                    preReopenFocusedPanelId: preReopenFocusedPanelId
                )
                return true
            }
        }

        return false
    }

    // MARK: - Closed-item-history reopen entry points

    /// Reopens the most-recently-closed history item, routing to the
    /// `AppDelegate` cross-window owner when one exists and otherwise driving the
    /// headless store-restore itself. Lifts the legacy `reopenMostRecentlyClosedItem`
    /// one-for-one: the `AppDelegate` short-circuit, then
    /// `ClosedItemHistoryStore.shared.restoreFirstRestorable` (whose per-entry
    /// switch + window restore the host owns), then `false`.
    @discardableResult
    public func reopenMostRecentlyClosedItem() -> Bool {
        guard let host else { return false }

        if let viaAppDelegate = host.reopenMostRecentlyClosedItemViaAppDelegate() {
            return viaAppDelegate
        }

        if host.restoreFirstRestorableStoreItem() {
            return true
        }

        return false
    }

    /// Reopens the closed-history item with `id`, routing to the `AppDelegate`
    /// cross-window owner when one exists and otherwise driving the headless
    /// remove → restore → re-insert-on-failure bookkeeping itself. Lifts the
    /// legacy `reopenClosedHistoryItem(id:)` one-for-one: a no-op `false` when the
    /// id is unknown; otherwise remove the record, restore its entry, and on
    /// failure re-insert it at its original store index.
    @discardableResult
    public func reopenClosedHistoryItem(id: UUID) -> Bool {
        guard let host else { return false }

        if let viaAppDelegate = host.reopenClosedHistoryItemViaAppDelegate(id: id) {
            return viaAppDelegate
        }

        guard let removed = host.removeStoreRecord(id: id) else {
            return false
        }

        let didRestore = host.restoreClosedHistoryEntry(host.historyEntry(of: removed))

        if !didRestore {
            host.reinsertRemovedRecord(removed)
        }
        return didRestore
    }
}
