import Foundation

/// Live-retargeting delivery and clear semantics for agent notifications
/// (https://github.com/manaflow-ai/cmux/issues/7939): a notification addressed
/// with a stale claimed workspace follows its surface to the workspace that
/// CURRENTLY owns it, and clears must use the same live identity so a
/// stale-keyed pending entry can never outlive a clear and resurrect. Split
/// from `TerminalNotificationQueue.swift` for the file-length budget.

extension TerminalController {
    func deliverNotificationSynchronously(
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        subtitle: String,
        body: String,
        retargetsToLiveSurfaceOwner: Bool = true
    ) {
        let target: (tabId: UUID, surfaceId: UUID?)
        if retargetsToLiveSurfaceOwner {
            // Trusted local delivery follows the surface's CURRENT workspace.
            // A missing live target fails closed instead of filing under a
            // stale claimed address.
            guard let liveTarget = AppDelegate.shared?.agentNotificationDeliveryTarget(
                claimedTabId: tabId,
                surfaceId: surfaceId
            ) else { return }
            target = liveTarget
        } else {
            // `notification.create_for_target` is relay-reachable and already
            // validated membership in its authorized workspace. Never global-
            // rehome that source-confined claim from an untrusted surface UUID.
            target = (tabId, surfaceId)
        }
        // Chronological feed delivery is append-only by accepted notification
        // id. A synchronous notification may supersede the phone/banner owner
        // for a pane, but it must not delete already accepted queued rows that
        // have not drained yet.
#if DEBUG
        cmuxDebugLog(
            "notification.sync.deliver workspace=\(target.tabId.uuidString.prefix(8)) surface=\(target.surfaceId?.uuidString.prefix(8) ?? "nil") claimedWorkspace=\(tabId.uuidString.prefix(8)) titleLen=\(title.count) subtitleLen=\(subtitle.count) bodyLen=\(body.count)"
        )
#endif
        TerminalNotificationStore.shared.addNotification(
            tabId: target.tabId,
            surfaceId: target.surfaceId,
            title: title,
            subtitle: subtitle,
            body: body,
            retargetsToLiveSurfaceOwner: retargetsToLiveSurfaceOwner
        )
    }
}

extension TerminalNotificationStore {
    /// Drain-time delivery of a queued notification. Resolves the LIVE target
    /// at delivery time: a surface-scoped notification follows its surface to
    /// the workspace that currently owns it (issues #7939/#5781) instead of
    /// being dropped on a stale workspace claim; only a gone target (closed
    /// surface/workspace) skips.
    func deliverQueuedNotification(
        claimedTabId: UUID,
        surfaceId: UUID?,
        title: String,
        subtitle: String,
        body: String,
        id: UUID,
        acceptedAt: Date,
        notificationGeneration: UInt64,
        allowWorkspaceFallbackForValidatedSurface: Bool = false
    ) {
        guard let target = AppDelegate.shared?.agentNotificationRecordTarget(
            claimedTabId: claimedTabId,
            surfaceId: surfaceId,
            allowWorkspaceFallbackForValidatedSurface: allowWorkspaceFallbackForValidatedSurface
        ) else {
#if DEBUG
            cmuxDebugLog(
                "notification.queue.deliver.skip workspace=\(claimedTabId.uuidString.prefix(8)) surface=\(surfaceId?.uuidString.prefix(8) ?? "nil") reason=targetMissing titleLen=\(title.count) subtitleLen=\(subtitle.count) bodyLen=\(body.count)"
            )
#endif
            return
        }
#if DEBUG
        cmuxDebugLog(
            "notification.queue.deliver workspace=\(target.tabId.uuidString.prefix(8)) surface=\(target.surfaceId?.uuidString.prefix(8) ?? "nil") claimedWorkspace=\(claimedTabId.uuidString.prefix(8)) titleLen=\(title.count) subtitleLen=\(subtitle.count) bodyLen=\(body.count)"
        )
#endif
        addNotification(
            id: id,
            acceptedAt: acceptedAt,
            tabId: target.tabId,
            surfaceId: target.surfaceId,
            title: title,
            subtitle: subtitle,
            body: body,
            retargetsToLiveSurfaceOwner: true,
            notificationGeneration: notificationGeneration
        )
    }

    /// Re-resolves canonical surface identity at the final apply boundary,
    /// after any asynchronous notification-policy hooks have finished.
    func notificationPolicyRequestAtLiveOwner(
        _ request: TerminalNotificationPolicyRequest
    ) -> TerminalNotificationPolicyRequest? {
        guard request.retargetsToLiveSurfaceOwner else { return request }
        guard let target = AppDelegate.shared?.agentNotificationRecordTarget(
            claimedTabId: request.tabId,
            surfaceId: request.surfaceId,
            allowWorkspaceFallbackForValidatedSurface: request.panelId != nil
        ) else { return nil }
        return TerminalNotificationPolicyRequest(
            tabId: target.tabId,
            surfaceId: target.surfaceId,
            panelId: target.surfaceId == nil ? nil : request.panelId,
            retargetsToLiveSurfaceOwner: true,
            title: request.title,
            subtitle: request.subtitle,
            body: request.body,
            cwd: request.cwd,
            isAppFocused: request.isAppFocused,
            isFocusedPanel: request.isFocusedPanel
        )
    }
}

@MainActor
extension TerminalMutationBus {
    /// A workspace-wide clear for `tabId` must also drop pending entries
    /// queued under a STALE claimed workspace whose surface's CURRENT owner is
    /// `tabId` — drain-time delivery retargets them there (#7939), so a
    /// claimed-key-only match would let the notification reappear right after
    /// the clear. Two-phase: snapshot the pending addresses under the bus
    /// lock, resolve each UNIQUE pending surface's live owner on the main
    /// actor (mirroring `agentNotificationDeliveryTarget`'s
    /// preferred-workspace resolution), then discard exactly the snapshotted
    /// stable notification ids from both pending entries and reliable
    /// admissions. Stable ids also cover an admission that becomes pending
    /// between the two lock acquisitions. Repeated non-coalescing
    /// notifications for one pane share a cached lookup, keeping the global
    /// workspace scan bounded by unique live surfaces instead of total backlog
    /// length. Entries accepted between snapshot and discard have new ids and
    /// are deliberately preserved.
    func pendingNotificationSequencesResolvingLiveOwner(forTabId tabId: UUID) -> Set<UInt64> {
        pendingNotificationSequencesResolvingLiveOwner(
            forTabId: tabId,
            liveOwnerResolver: { claimedTabId, surfaceId in
                AppDelegate.shared?.agentNotificationDeliveryTarget(
                    claimedTabId: claimedTabId,
                    surfaceId: surfaceId
                )?.tabId
            }
        )
    }

    func pendingNotificationSequencesResolvingLiveOwner(
        forTabId tabId: UUID,
        liveOwnerResolver: (_ claimedTabId: UUID, _ surfaceId: UUID) -> UUID?
    ) -> Set<UInt64> {
        var sequences: Set<UInt64> = []
        var liveOwnerBySurfaceId: [UUID: UUID] = [:]
        var unresolvedSurfaceIds: Set<UUID> = []
        for entry in pendingNotificationAddressesSnapshot() {
            guard let surfaceId = entry.surfaceId else {
                if entry.tabId == tabId { sequences.insert(entry.sequence) }
                continue
            }
            let liveOwner: UUID?
            if let cached = liveOwnerBySurfaceId[surfaceId] {
                liveOwner = cached
            } else if unresolvedSurfaceIds.contains(surfaceId) {
                liveOwner = nil
            } else if let resolved = liveOwnerResolver(entry.tabId, surfaceId) {
                liveOwnerBySurfaceId[surfaceId] = resolved
                liveOwner = resolved
            } else {
                unresolvedSurfaceIds.insert(surfaceId)
                liveOwner = nil
            }
            if liveOwner == tabId ||
                (liveOwner == nil &&
                    entry.allowWorkspaceFallbackForValidatedSurface &&
                    entry.tabId == tabId) {
                sequences.insert(entry.sequence)
            }
        }
        return sequences
    }

    func queuedNotificationIDsResolvingLiveOwner(
        forTabId tabId: UUID,
        liveOwnerResolver: (_ claimedTabId: UUID, _ surfaceId: UUID) -> UUID?
    ) -> Set<UUID> {
        var ids: Set<UUID> = []
        var liveOwnerBySurfaceId: [UUID: UUID] = [:]
        var unresolvedSurfaceIds: Set<UUID> = []
        for entry in queuedNotificationAddressesSnapshot() {
            guard let surfaceId = entry.surfaceId else {
                if entry.tabId == tabId { ids.insert(entry.id) }
                continue
            }
            let liveOwner: UUID?
            if let cached = liveOwnerBySurfaceId[surfaceId] {
                liveOwner = cached
            } else if unresolvedSurfaceIds.contains(surfaceId) {
                liveOwner = nil
            } else if let resolved = liveOwnerResolver(entry.tabId, surfaceId) {
                liveOwnerBySurfaceId[surfaceId] = resolved
                liveOwner = resolved
            } else {
                unresolvedSurfaceIds.insert(surfaceId)
                liveOwner = nil
            }
            if liveOwner == tabId ||
                (liveOwner == nil &&
                    entry.allowWorkspaceFallbackForValidatedSurface &&
                    entry.tabId == tabId) {
                ids.insert(entry.id)
            }
        }
        return ids
    }

    func discardPendingNotificationsResolvingLiveOwner(forTabId tabId: UUID) {
        discardQueuedNotifications(
            ids: queuedNotificationIDsResolvingLiveOwner(
                forTabId: tabId,
                liveOwnerResolver: { claimedTabId, surfaceId in
                    AppDelegate.shared?.agentNotificationDeliveryTarget(
                        claimedTabId: claimedTabId,
                        surfaceId: surfaceId
                    )?.tabId
                }
            )
        )
    }
}
