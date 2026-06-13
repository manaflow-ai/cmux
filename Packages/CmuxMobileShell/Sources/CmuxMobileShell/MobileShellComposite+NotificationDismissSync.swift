internal import CmuxMobileDiagnostics
internal import CmuxMobileRPC
internal import Foundation
internal import OSLog

private let mobileShellLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

extension MobileShellComposite {
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
            mobileShellLog.error("notification dismiss sync failed count=\(trimmed.count, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    func flushPendingNotificationDismisses() async {
        let pending = pendingDismissQueue.pendingIDs
        guard !pending.isEmpty else { return }
        await dismissNotification(ids: pending)
    }

    public func clearDeliveredNotifications(ids: [String]) async {
        let trimmed = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return }
        await deliveredNotificationClearer.removeDelivered(ids: trimmed)
    }

    public func applyAuthoritativeUnreadBadge(_ count: Int) {
        deliveredNotificationClearer.setBadgeCount(max(0, count))
    }

    func scheduleNotificationReconcile(client: MobileCoreRPCClient) {
        Task { [weak self] in
            await self?.flushPendingNotificationDismisses()
            await self?.reconcileNotificationsWithMac(client: client)
        }
    }

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
            MobileDebugLog.anchormux("notif.reconcile_failed error=\(error)")
        }
    }

    func applyNotificationReconcile(_ response: MobileNotificationReconcileResponse) async {
        if !response.handledIDs.isEmpty {
            await clearDeliveredNotifications(ids: response.handledIDs)
        }
        if let unreadCount = response.unreadCount {
            applyAuthoritativeUnreadBadge(unreadCount)
        }
    }
}
