import Foundation

/// Mobile-host notification verbs (cross-device dismiss-sync): the
/// `notification.dismiss` and `notification.reconcile` RPC handlers dispatched
/// from `mobileHostHandleRPC(_:)`.
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
        // Cap the scan like `notification.reconcile`: a phone cannot meaningfully
        // dismiss more than this in one request (its durable outbox holds 128),
        // so anything past the cap is a malformed or hostile frame and is
        // ignored instead of trimmed/parsed on the main actor.
        let maxDismissIDs = 256
        var rawIDs: [String] = []
        if let single = v2OptionalTrimmedRawString(params, "notification_id") {
            rawIDs.append(single)
        }
        if let array = params["notification_ids"] as? [Any] {
            for value in array.prefix(maxDismissIDs) {
                if let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !string.isEmpty {
                    rawIDs.append(string)
                }
            }
        }
        // Dedupe (preserving order) so a repeated id cannot double-count in
        // `dismissed` or run the markRead path twice.
        var seenIDs = Set<UUID>()
        let ids = rawIDs
            .compactMap { UUID(uuidString: $0) }
            .filter { seenIDs.insert($0).inserted }
        guard !ids.isEmpty else {
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
        var dismissed = 0
        for id in ids where unreadIDs.contains(id) {
            store.markRead(id: id)
            dismissed += 1
        }
        return .ok(["dismissed": dismissed])
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
        // Cap the scan: iOS keeps only the most recent delivered notifications,
        // so anything past this is a malformed or hostile request.
        let maxDeliveredIDs = 256
        let rawIDs = ((params["delivered_ids"] as? [Any]) ?? []).prefix(maxDeliveredIDs)
        let deliveredIDs = rawIDs.compactMap { value -> UUID? in
            guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !string.isEmpty else {
                return nil
            }
            return UUID(uuidString: string)
        }
        let store = TerminalNotificationStore.shared
        return .ok([
            "handled_ids": store.reconcileHandledNotificationIDs(deliveredIDs: deliveredIDs),
            "unread_count": store.unreadNotificationCount,
        ])
    }

    /// The `workspace.action` sub-actions the mobile data plane may invoke.
    ///
    /// Mobile gets pin/unpin/rename/read-state only. The other sub-actions of
    /// ``v2WorkspaceAction(params:)`` reorder the global sidebar or destroy
    /// sibling workspaces, so they stay on the Mac/automation socket. The action
    /// is normalized exactly as ``v2ActionKey(_:_:)`` so this gate and the
    /// handler can never disagree on which action runs.
    /// - Parameter rawAction: The raw `action` param value.
    /// - Returns: `true` when the normalized action is mobile-allowed.
    nonisolated static func mobileAllowsWorkspaceAction(_ rawAction: String?) -> Bool {
        guard let trimmed = rawAction?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return false }
        let normalized = trimmed.lowercased().replacingOccurrences(of: "-", with: "_")
        return ["pin", "unpin", "rename", "mark_read", "mark_unread"].contains(normalized)
    }
}
