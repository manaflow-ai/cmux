import Foundation

/// Mobile-host notification-feed verbs dispatched from
/// `mobileHostHandleRPC(_:)`.
extension TerminalController {
    /// Returns the Mac notification store in authoritative newest-first order,
    /// with display names resolved through the same all-window workspace list
    /// used by the phone. Missing workspaces simply omit `workspace_name`.
    ///
    /// The optional `limit` is clamped to `1...500` and defaults to 500. The
    /// payload contains notification content because this authenticated feed is
    /// the content surface; errors remain generic and never echo that content.
    func v2MobileNotificationList(params: [String: Any]) -> V2CallResult {
        let requestedLimit = params["limit"] as? Int ?? 500
        let limit = min(max(requestedLimit, 1), 500)
        let store = TerminalNotificationStore.shared
        let workspaceNames = mobileNotificationWorkspaceNames()
        let notifications = store.notifications.prefix(limit).map { notification in
            var item: [String: Any] = [
                "id": notification.id.uuidString,
                "workspace_id": notification.tabId.uuidString,
                "title": notification.title,
                "subtitle": notification.subtitle,
                "body": notification.body,
                "created_at": notification.createdAt.timeIntervalSince1970,
                "is_read": notification.isRead,
            ]
            if let surfaceId = notification.surfaceId {
                item["surface_id"] = surfaceId.uuidString
            }
            if let workspaceName = workspaceNames[notification.tabId] {
                item["workspace_name"] = workspaceName
            }
            return item
        }
        return .ok([
            "notifications": notifications,
            "unread_count": store.unreadNotificationCount,
        ])
    }

    /// Marks currently-read notifications unread. Accepts either a single
    /// `notification_id` or a `notification_ids` array; trims, caps, and dedupes
    /// the same way as ``v2MobileNotificationDismiss(params:)`` while ignoring
    /// unknown ids. The result counts only actual read-to-unread transitions.
    /// Carries only opaque UUIDs and a count, never terminal content.
    func v2MobileNotificationMarkUnread(params: [String: Any]) -> V2CallResult {
        let ids = mobileNotificationFeedIDs(params: params)
        guard !ids.isEmpty else {
            return .err(
                code: "invalid_params",
                message: "Missing or invalid notification_id / notification_ids",
                data: nil
            )
        }
        let store = TerminalNotificationStore.shared
        let readIDs = Set(store.notifications.filter(\.isRead).map(\.id))
        var marked = 0
        for id in ids where readIDs.contains(id) {
            store.markUnread(id: id)
            marked += 1
        }
        return .ok(["marked": marked])
    }

    /// Removes notifications present in the Mac store. Accepts either a single
    /// `notification_id` or a `notification_ids` array; trims, caps, and dedupes
    /// the same way as ``v2MobileNotificationDismiss(params:)`` while treating
    /// unknown ids as no-ops. Carries only opaque UUIDs and a count, never
    /// terminal content.
    func v2MobileNotificationRemove(params: [String: Any]) -> V2CallResult {
        let ids = mobileNotificationFeedIDs(params: params)
        guard !ids.isEmpty else {
            return .err(
                code: "invalid_params",
                message: "Missing or invalid notification_id / notification_ids",
                data: nil
            )
        }
        let store = TerminalNotificationStore.shared
        let presentIDs = Set(store.notifications.map(\.id))
        var removed = 0
        for id in ids where presentIDs.contains(id) {
            store.remove(id: id)
            removed += 1
        }
        return .ok(["removed": removed])
    }

    /// Parses the feed mutation id aliases with the same bounded, order-stable
    /// defensive posture as the existing mobile dismiss handler.
    private func mobileNotificationFeedIDs(params: [String: Any]) -> [UUID] {
        // The phone cannot meaningfully mutate more than 256 notifications in
        // one request. Ignore anything past the array cap rather than scanning a
        // malformed or hostile frame on the main actor.
        let maxNotificationIDs = 256
        var rawIDs: [String] = []
        if let single = v2OptionalTrimmedRawString(params, "notification_id") {
            rawIDs.append(single)
        }
        if let array = params["notification_ids"] as? [Any] {
            for value in array.prefix(maxNotificationIDs) {
                if let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !string.isEmpty {
                    rawIDs.append(string)
                }
            }
        }
        // Preserve the caller's order while preventing a replayed id from
        // double-counting or running the mutation path twice.
        var seenIDs = Set<UUID>()
        return rawIDs
            .compactMap { UUID(uuidString: $0) }
            .filter { seenIDs.insert($0).inserted }
    }

    /// Builds names from the existing mobile workspace-list response so feed
    /// lookup semantics cannot drift into a parallel tab/window resolver.
    private func mobileNotificationWorkspaceNames() -> [UUID: String] {
        guard case let .ok(rawPayload) = v2MobileWorkspaceList(params: [:]),
              let payload = rawPayload as? [String: Any],
              let workspaces = payload["workspaces"] as? [[String: Any]] else {
            return [:]
        }
        var names: [UUID: String] = [:]
        for workspace in workspaces {
            guard let rawID = workspace["id"] as? String,
                  let id = UUID(uuidString: rawID),
                  let title = workspace["title"] as? String else {
                continue
            }
            names[id] = title
        }
        return names
    }
}
