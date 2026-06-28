import CMUXMobileCore
import Foundation

/// Mobile-host notification verbs (cross-device dismiss-sync): the
/// `notification.dismiss` and `notification.reconcile` RPC handlers dispatched
/// from `mobileHostHandleRPC(_:)`.
///
/// The wire parsing and the dismiss decision live in
/// ``MobileNotificationSyncRequest`` (in the shared `CMUXMobileCore` package,
/// next to ``MobileWorkspaceAction``) as pure, testable value logic; these
/// witnesses own only the irreducible live-state seam — extracting the raw
/// params, snapshotting and mutating ``TerminalNotificationStore`` on the main
/// actor, and building the wire payload.
extension TerminalController {
    /// Mark notifications read on the Mac in response to the user dismissing the
    /// mirrored banner on a paired phone. Accepts either a single `notification_id`
    /// or a `notification_ids` array; ignores unknown/malformed ids.
    ///
    /// Deliberately uses ``TerminalNotificationStore/markRead(id:)`` — NOT
    /// `remove` — so it mirrors a Mac banner *swipe* (which the Mac's own
    /// `UNUserNotificationCenterDelegate` handles via `markRead`, keeping the
    /// entry in the notification list while clearing the banner + unread). This
    /// is distinct from the socket `notification.dismiss` verb
    /// (``v2NotificationDismiss(params:)``), which fully `remove`s the entry. The
    /// resulting `markRead` emits `notification.dismissed` back, a harmless no-op
    /// for the already-removed phone banner. Carries only opaque UUIDs, never
    /// terminal content.
    func v2MobileNotificationDismiss(params: [String: Any]) -> V2CallResult {
        let request = MobileNotificationSyncRequest(
            dismissSingleID: v2RawString(params, "notification_id"),
            arrayIDs: (params["notification_ids"] as? [Any])?.map { $0 as? String }
        )
        guard !request.ids.isEmpty else {
            return .err(
                code: "invalid_params",
                message: "Missing or invalid notification_id / notification_ids",
                data: nil
            )
        }
        let store = TerminalNotificationStore.shared
        // `dismissed` counts notifications that actually transitioned unread→read,
        // not the number of ids supplied: unknown or already-read ids are no-ops,
        // so a stale/duplicate phone dismiss reports 0 rather than a misleading hit.
        let unreadIDs = Set(store.notifications.filter { !$0.isRead }.map(\.id))
        let toDismiss = request.dismissPlan(unreadIDs: unreadIDs)
        for id in toDismiss {
            store.markRead(id: id)
        }
        return .ok(["dismissed": toDismiss.count])
    }

    /// Foreground reconcile sweep for the phone (lane 3 of dismiss-sync): given
    /// the banner ids currently delivered on the phone, report which were handled
    /// on this Mac — read in the store, or recently dismissed/removed
    /// (tombstoned) — plus the authoritative unread count, so the phone clears
    /// stale banners and SETS its icon badge to the computed total. Ids unknown
    /// to this Mac are not reported handled (they may belong to a different
    /// paired Mac). An empty `delivered_ids` is a valid badge-only sync.
    /// Exchanges only opaque UUIDs and a count, never terminal content.
    func v2MobileNotificationReconcile(params: [String: Any]) -> V2CallResult {
        let request = MobileNotificationSyncRequest(
            deliveredArrayIDs: (params["delivered_ids"] as? [Any])?.map { $0 as? String }
        )
        let store = TerminalNotificationStore.shared
        return .ok([
            "handled_ids": store.reconcileHandledNotificationIDs(deliveredIDs: request.ids),
            "unread_count": store.unreadNotificationCount,
        ])
    }

    /// The `workspace.action` sub-actions the mobile data plane may invoke.
    ///
    /// Mobile gets pin/unpin/rename/read-state only. The other `workspace.action`
    /// sub-actions reorder the global sidebar or destroy sibling workspaces, so
    /// they stay on the Mac/automation socket. The
    /// allow-list and its normalization (trim, lowercase, map `-` to `_`, exactly
    /// as ``v2ActionKey(_:_:)``) live in ``MobileWorkspaceAction`` in the shared
    /// `CMUXMobileCore` package so this gate and the handler can never disagree on
    /// which action runs. The gating decision is folded into
    /// ``MobileHostParamPolicy``, the host's pure param-policy value type.
    /// - Parameter rawAction: The raw `action` param value.
    /// - Returns: `true` when the normalized action is mobile-allowed.
    nonisolated static func mobileAllowsWorkspaceAction(_ rawAction: String?) -> Bool {
        MobileHostParamPolicy().allowsWorkspaceAction(rawAction)
    }
}
