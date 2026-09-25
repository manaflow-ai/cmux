import CMUXMobileCore
import Foundation

/// Mobile-host notification verbs (cross-device dismiss-sync): the
/// `notification.dismiss` and `notification.reconcile` RPC handlers dispatched
/// from `mobileHostHandleRPC(_:)`.
extension TerminalController {
    private nonisolated static let mobileNotificationFeedResponseByteLimit =
        MobileSyncFrameCodec.defaultMaximumFrameByteCount - (64 * 1024)
    private nonisolated static let mobileNotificationFeedTitleByteLimit = 512
    private nonisolated static let mobileNotificationFeedSubtitleByteLimit = 512
    private nonisolated static let mobileNotificationFeedBodyByteLimit = 4_096
    private nonisolated static let mobileNotificationFeedMetadataByteLimit = 512

    /// Returns the Mac-owned notification history, newest first. The paired
    /// phone merges snapshots from all connected Macs into its global feed.
    func v2MobileNotificationFeedList(
        params _: [String: Any],
        responseID: String? = "notification.feed.list"
    ) async -> V2CallResult {
        let store = TerminalNotificationStore.shared
        store.notificationFeedHistory.reconcileActiveNotifications(store.notifications)
        let snapshot = store.notificationFeedHistory.snapshot
        let items = snapshot.notifications.map(mobileNotificationFeedWireItem)
        let fittedItems = await Self.mobileNotificationFeedItemsFittingFrame(
            responseID: responseID,
            revision: snapshot.revision,
            items: items
        )
        return .ok([
            "revision": snapshot.revision,
            "notifications": fittedItems.map(\.foundationPayload),
        ])
    }

    private nonisolated static func mobileNotificationFeedItemsFittingFrame(
        responseID: String?,
        revision: Int,
        items: [MobileNotificationFeedWireItem]
    ) async -> [MobileNotificationFeedWireItem] {
        let worker = Task.detached(priority: .utility) {
            mobileNotificationFeedItemsFittingFrameOnWorker(
                responseID: responseID,
                revision: revision,
                items: items
            )
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private nonisolated static func mobileNotificationFeedItemsFittingFrameOnWorker(
        responseID: String?,
        revision: Int,
        items: [MobileNotificationFeedWireItem]
    ) -> [MobileNotificationFeedWireItem] {
        guard !Task.isCancelled else { return [] }
        guard !items.isEmpty else {
            return items
        }

        let emptyResponseByteCount = mobileNotificationFeedEmptyResponseByteCount(
            responseID: responseID,
            revision: revision
        )
        guard emptyResponseByteCount <= mobileNotificationFeedResponseByteLimit else {
            return []
        }

        var responseByteCount = emptyResponseByteCount - 2
        var fittedCount = 0
        for item in items {
            guard !Task.isCancelled else {
                return Array(items.prefix(fittedCount))
            }
            let rowByteCount = mobileNotificationFeedRowByteCount(item)
            let separatorByteCount = fittedCount == 0 ? 0 : 1
            let remainingByteCount = mobileNotificationFeedResponseByteLimit
                - responseByteCount
                - separatorByteCount
            guard rowByteCount <= remainingByteCount else {
                break
            }
            responseByteCount += separatorByteCount + rowByteCount
            fittedCount += 1
        }
        guard fittedCount < items.count else { return items }
        return Array(items.prefix(fittedCount))
    }

    private nonisolated static func mobileNotificationFeedEmptyResponseByteCount(
        responseID: String?,
        revision: Int
    ) -> Int {
        let payload: [String: Any] = [
            "revision": revision,
            "notifications": [],
        ]
        let encoded = MobileHostRPCEnvelope.encodeResponse(
            id: responseID,
            result: .ok(payload)
        )
        return encoded.count
    }

    private nonisolated static func mobileNotificationFeedRowByteCount(
        _ item: MobileNotificationFeedWireItem
    ) -> Int {
        let payload = item.foundationPayload
        guard JSONSerialization.isValidJSONObject(payload),
              let encoded = try? JSONSerialization.data(withJSONObject: payload) else {
            return Int.max
        }
        return encoded.count
    }

    /// Marks the supplied feed records read and mirrors matching active
    /// notifications through the desktop store's existing mutation path.
    func v2MobileNotificationFeedMarkRead(params: [String: Any]) -> V2CallResult {
        guard let ids = mobileNotificationFeedIDs(params: params) else {
            return .err(
                code: "invalid_params",
                message: "Missing or invalid notification_ids",
                data: nil
            )
        }
        let store = TerminalNotificationStore.shared
        let marked = store.markNotificationFeedRead(ids: ids)
        return .ok([
            "marked": marked,
            "revision": store.notificationFeedHistory.revision,
        ])
    }

    /// Marks the supplied feed records unread and mirrors matching active
    /// notifications without redelivering their system banners.
    func v2MobileNotificationFeedMarkUnread(params: [String: Any]) -> V2CallResult {
        guard let ids = mobileNotificationFeedIDs(params: params) else {
            return .err(
                code: "invalid_params",
                message: "Missing or invalid notification_ids",
                data: nil
            )
        }
        let store = TerminalNotificationStore.shared
        let marked = store.markNotificationFeedUnread(ids: ids)
        return .ok([
            "marked": marked,
            "revision": store.notificationFeedHistory.revision,
        ])
    }

    /// Marks every feed record read while preserving the chronological history.
    func v2MobileNotificationFeedMarkAllRead(params _: [String: Any]) -> V2CallResult {
        let store = TerminalNotificationStore.shared
        let marked = store.notificationFeedHistory.notifications.lazy.filter { !$0.isRead }.count
        store.markAllRead()
        return .ok([
            "marked": marked,
            "revision": store.notificationFeedHistory.revision,
        ])
    }

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

    private func mobileNotificationFeedWireItem(
        _ record: NotificationFeedHistoryRecord
    ) -> MobileNotificationFeedWireItem {
        let targetSurfaceID = record.panelId ?? record.surfaceId
        var targetWorkspaceID = record.tabId
        if record.retargetsToLiveSurfaceOwner,
           let targetSurfaceID,
           let liveTarget = AppDelegate.shared?.agentNotificationDeliveryTarget(
               claimedTabId: record.tabId,
               surfaceId: targetSurfaceID
        ) {
            targetWorkspaceID = liveTarget.tabId
        }
        var workspaceTitle: String?
        var surfaceTitle: String?
        if let workspace = AppDelegate.shared?
            .tabManagerFor(tabId: targetWorkspaceID)?
            .workspacesById[targetWorkspaceID] {
            workspaceTitle = workspace.title
            if let targetSurfaceID,
               let resolvedSurfaceTitle = workspace.panelTitle(panelId: targetSurfaceID) {
                surfaceTitle = resolvedSurfaceTitle
            }
        }
        return MobileNotificationFeedWireItem(
            id: record.id.uuidString,
            workspaceID: targetWorkspaceID.uuidString,
            surfaceID: targetSurfaceID?.uuidString,
            title: Self.mobileNotificationFeedString(
                record.title,
                limitedToUTF8Bytes: Self.mobileNotificationFeedTitleByteLimit
            ),
            subtitle: Self.mobileNotificationFeedString(
                record.subtitle,
                limitedToUTF8Bytes: Self.mobileNotificationFeedSubtitleByteLimit
            ),
            body: Self.mobileNotificationFeedString(
                record.body,
                limitedToUTF8Bytes: Self.mobileNotificationFeedBodyByteLimit
            ),
            createdAt: record.createdAt.timeIntervalSince1970,
            isRead: record.isRead,
            retargetsToLiveSurfaceOwner: record.retargetsToLiveSurfaceOwner,
            workspaceTitle: workspaceTitle.map {
                Self.mobileNotificationFeedString(
                    $0,
                    limitedToUTF8Bytes: Self.mobileNotificationFeedMetadataByteLimit
                )
            },
            surfaceTitle: surfaceTitle.map {
                Self.mobileNotificationFeedString(
                    $0,
                    limitedToUTF8Bytes: Self.mobileNotificationFeedMetadataByteLimit
                )
            }
        )
    }

    private nonisolated static func mobileNotificationFeedString(
        _ value: String,
        limitedToUTF8Bytes maxBytes: Int
    ) -> String {
        guard maxBytes >= 0, value.utf8.count > maxBytes else { return value }
        var byteCount = 0
        var endIndex = value.startIndex
        while endIndex < value.endIndex {
            let nextIndex = value.index(after: endIndex)
            let characterByteCount = value[endIndex..<nextIndex].utf8.count
            guard byteCount + characterByteCount <= maxBytes else { break }
            byteCount += characterByteCount
            endIndex = nextIndex
        }
        return String(value[..<endIndex])
    }

    private func mobileNotificationFeedIDs(params: [String: Any]) -> Set<UUID>? {
        let maxNotificationIDs = 2_000
        guard let rawIDs = params["notification_ids"] as? [Any] else { return nil }
        let ids = Set(rawIDs.prefix(maxNotificationIDs).compactMap { value -> UUID? in
            guard let rawID = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return nil
            }
            return UUID(uuidString: rawID)
        })
        return ids.isEmpty ? nil : ids
    }

    /// The `workspace.action` sub-actions the mobile data plane may invoke.
    ///
    /// Mobile gets workspace identity and read-state mutations. The other
    /// sub-actions of ``v2WorkspaceAction(params:)`` reorder the global sidebar
    /// or destroy sibling workspaces, so they stay on the Mac/automation socket.
    /// The action is normalized exactly as ``v2ActionKey(_:_:)`` so this gate and
    /// the handler can never disagree on which action runs.
    /// - Parameter rawAction: The raw `action` param value.
    /// - Returns: `true` when the normalized action is mobile-allowed.
    nonisolated static func mobileAllowsWorkspaceAction(_ rawAction: String?) -> Bool {
        guard let normalized = mobileWorkspaceActionKey(rawAction) else { return false }
        return [
            "pin", "unpin", "rename",
            "set_description", "clear_description",
            "set_color", "clear_color",
            "mark_read", "mark_unread",
        ].contains(normalized)
    }

    /// Normalized mobile workspace-action key.
    nonisolated static func mobileWorkspaceActionKey(_ rawAction: String?) -> String? {
        guard let trimmed = rawAction?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed.lowercased().replacingOccurrences(of: "-", with: "_")
    }
}
