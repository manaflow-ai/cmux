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
        // Retarget to the surface's CURRENT workspace at delivery time so a
        // stale caller-supplied workspace id (spawn-time env, moved pane —
        // issues #7939/#5781) cannot misfile the notification. Undeliverable
        // targets fall back to the claimed address, preserving prior behavior.
        let target = AppDelegate.shared?.agentNotificationDeliveryTarget(
            claimedTabId: tabId,
            surfaceId: surfaceId
        ) ?? (tabId: tabId, surfaceId: surfaceId)
        // Supersede pending notifications by canonical identity: stale-keyed
        // entries for this surface would retarget to this same pane at drain.
        if let liveSurfaceId = target.surfaceId {
            TerminalMutationBus.shared.discardPendingNotifications(forSurfaceId: liveSurfaceId)
        } else {
            TerminalMutationBus.shared.discardPendingNotifications(forTabId: target.tabId, surfaceId: nil)
        }
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
        body: String
    ) {
        guard let target = AppDelegate.shared?.agentNotificationDeliveryTarget(
            claimedTabId: claimedTabId,
            surfaceId: surfaceId
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
            tabId: target.tabId,
            surfaceId: target.surfaceId,
            title: title,
            subtitle: subtitle,
            body: body,
            retargetsToLiveSurfaceOwner: true
        )
    }

    /// Re-resolves canonical surface identity at the final apply boundary,
    /// after any asynchronous notification-policy hooks have finished.
    func notificationPolicyRequestAtLiveOwner(
        _ request: TerminalNotificationPolicyRequest
    ) -> TerminalNotificationPolicyRequest? {
        guard request.retargetsToLiveSurfaceOwner else { return request }
        guard let target = AppDelegate.shared?.agentNotificationDeliveryTarget(
            claimedTabId: request.tabId,
            surfaceId: request.surfaceId
        ) else { return nil }
        return TerminalNotificationPolicyRequest(
            tabId: target.tabId,
            surfaceId: target.surfaceId,
            panelId: request.panelId,
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
    /// sequences. Repeated non-coalescing notifications for one pane share a
    /// cached lookup, keeping the global workspace scan bounded by unique live
    /// surfaces instead of total backlog length. Entries enqueued between
    /// snapshot and discard are newer than the clear and are deliberately
    /// preserved.
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
            if liveOwner == tabId {
                sequences.insert(entry.sequence)
            }
        }
        return sequences
    }

    func discardPendingNotificationsResolvingLiveOwner(forTabId tabId: UUID) {
        discardPendingNotifications(
            sequences: pendingNotificationSequencesResolvingLiveOwner(forTabId: tabId)
        )
    }
}
