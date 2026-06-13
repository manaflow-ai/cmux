internal import CmuxMobileDiagnostics
internal import CmuxMobileRPC
internal import Foundation
internal import OSLog

private let mobileShellLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

extension MobileShellComposite {
    // MARK: - Notification dismiss-sync

    /// Tell the Mac that one or more mirrored notifications were dismissed on
    /// this phone (a swipe/clear on the delivered banner). The Mac marks them
    /// read and clears its own banner; its store then emits `notification.dismissed`
    /// back, which is a harmless no-op for the already-removed phone banner.
    ///
    /// Fire-and-forget against the authoritative Mac store, but durable: the ids
    /// are enqueued in ``PendingNotificationDismissQueue`` BEFORE the RPC is
    /// attempted and removed only after it succeeds, so a dismiss that races a
    /// dead/absent attach channel is retried by ``flushPendingNotificationDismisses()``
    /// on the next successful (re)subscribe instead of being dropped.
    ///
    /// Carries only opaque notification UUIDs, never terminal content, so it is
    /// safe regardless of the Mac's phone-forward hideContent setting.
    /// - Parameter ids: The stable notification ids the user dismissed.
    public func dismissNotification(ids: [String]) async {
        let trimmed = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return }
        pendingDismissQueue.enqueue(trimmed)
        guard let client = remoteClient else { return }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "notification.dismiss",
                params: [
                    "notification_ids": trimmed,
                    "client_id": clientID,
                ]
            )
            _ = try await client.sendRequest(request)
            pendingDismissQueue.remove(trimmed)
        } catch {
            // Left in the queue; the next successful (re)subscribe re-sends.
            mobileShellLog.error("notification dismiss sync failed count=\(trimmed.count, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    /// Re-send every dismissal still waiting in the durable outbox (a swipe that
    /// happened while detached, backgrounded, or before any scene existed). The
    /// Mac ignores ids it does not know, so replaying stale entries is harmless.
    func flushPendingNotificationDismisses() async {
        let pending = pendingDismissQueue.pendingIDs
        guard !pending.isEmpty else { return }
        await dismissNotification(ids: pending)
    }

    /// Clear delivered banners on this phone in response to a Mac-side dismiss
    /// (`notification.dismissed` peer event). The ids are stable Mac-side
    /// notification ids; the injected ``DeliveredNotificationClearing`` seam
    /// maps them to the matching delivered banners via their
    /// `cmux.notificationId` payload key.
    /// - Parameter ids: The notification ids the Mac dismissed.
    public func clearDeliveredNotifications(ids: [String]) async {
        let trimmed = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return }
        await deliveredNotificationClearer.removeDelivered(ids: trimmed)
    }

    /// SET the app-icon badge to the Mac's authoritative unread total. Always an
    /// absolute write (never local +/-1 arithmetic) so any drift self-heals on
    /// the next event, push, or reconcile sweep.
    /// - Parameter count: The Mac's unread-notification count.
    public func applyAuthoritativeUnreadBadge(_ count: Int) {
        deliveredNotificationClearer.setBadgeCount(max(0, count))
    }

    /// Kick off one foreground/connect dismiss-sync pass against `client`:
    /// first flush the durable phone→Mac dismiss outbox (so the Mac's store
    /// reflects every swipe that happened while detached), then run the
    /// reconcile sweep (lane 3) whose answer therefore already includes them.
    /// Fire-and-forget; failures are non-fatal because the next (re)subscribe
    /// runs another pass.
    func scheduleNotificationReconcile(client: MobileCoreRPCClient) {
        Task { [weak self] in
            await self?.flushPendingNotificationDismisses()
            await self?.reconcileNotificationsWithMac(client: client)
        }
    }

    /// The reconcile sweep: send the Mac the ids of every banner currently
    /// delivered on this phone; it answers with the subset handled there (read,
    /// or recently dismissed/removed) plus its authoritative unread count. Remove
    /// the handled banners and SET the badge. This heals whatever the live event
    /// lane and the budgeted silent-push lane missed while the app was closed.
    /// Ids the Mac does not recognize are left alone (they may mirror a
    /// different paired Mac). Exchanges only opaque ids and a count.
    func reconcileNotificationsWithMac(client: MobileCoreRPCClient) async {
        let deliveredIDs = await deliveredNotificationClearer.deliveredIdentifiers()
        guard remoteClient === client, connectionState == .connected else { return }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "notification.reconcile",
                params: [
                    "delivered_ids": deliveredIDs,
                    "client_id": clientID,
                ]
            )
            let data = try await client.sendRequest(request)
            guard remoteClient === client else { return }
            let response = try MobileNotificationReconcileResponse.decode(data)
            await applyNotificationReconcile(response)
            MobileDebugLog.anchormux(
                "notif.reconcile delivered=\(deliveredIDs.count) handled=\(response.handledIDs.count) unread=\(response.unreadCount.map(String.init) ?? "nil")"
            )
        } catch {
            // Older Macs don't implement the verb (method_not_found), and
            // transport hiccups are non-fatal: the next (re)subscribe retries.
            MobileDebugLog.anchormux("notif.reconcile_failed error=\(error)")
        }
    }

    /// Apply a reconcile result: clear the banners the Mac reports handled and
    /// SET the badge to its authoritative count. Split from the transport so the
    /// behavior is unit-testable through the injected clearing seam.
    func applyNotificationReconcile(_ response: MobileNotificationReconcileResponse) async {
        if !response.handledIDs.isEmpty {
            await clearDeliveredNotifications(ids: response.handledIDs)
        }
        if let unreadCount = response.unreadCount {
            applyAuthoritativeUnreadBadge(unreadCount)
        }
    }
}
