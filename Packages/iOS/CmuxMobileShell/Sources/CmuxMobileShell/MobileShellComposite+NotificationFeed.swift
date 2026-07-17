public import CmuxMobileRPC
internal import CmuxMobileShellModel
public import Foundation
internal import OSLog

private let notificationFeedLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "notification-feed"
)

extension MobileShellComposite {
    /// Refetches the active Mac's notification feed and applies it authoritatively.
    public func refreshNotificationFeed() async {
        guard notificationFeed.beginRefresh() else { return }
        while true {
            await performNotificationFeedRefresh()
            guard notificationFeed.finishRefresh() else { return }
            guard notificationFeed.beginRefresh() else { return }
        }
    }

    /// Coalesces live feed-change events onto the feed's single refresh slot.
    func scheduleNotificationFeedRefreshFromEvent() {
        guard remoteClient != nil else { return }
        Task { @MainActor [weak self] in
            await self?.refreshNotificationFeed()
        }
    }

    /// Optimistically marks notifications read, then converges with the Mac.
    /// - Parameter ids: Stable notification identifiers.
    public func markNotificationsRead(ids: [UUID]) async {
        let ids = Array(Set(ids))
        guard !ids.isEmpty else { return }
        notificationFeed.markRead(ids)
        guard await sendNotificationFeedMutation(method: "notification.dismiss", ids: ids) else {
            await refreshNotificationFeed()
            return
        }
    }

    /// Optimistically marks one notification unread, then converges with the Mac.
    /// - Parameter id: Stable notification identifier.
    public func markNotificationUnread(id: UUID) async {
        notificationFeed.markUnread(id)
        guard await sendNotificationFeedMutation(method: "notification.mark_unread", ids: [id]) else {
            await refreshNotificationFeed()
            return
        }
    }

    /// Optimistically removes notifications, then converges with the Mac.
    /// - Parameter ids: Stable notification identifiers.
    public func removeNotifications(ids: [UUID]) async {
        let ids = Array(Set(ids))
        guard !ids.isEmpty else { return }
        notificationFeed.remove(ids)
        guard await sendNotificationFeedMutation(method: "notification.remove", ids: ids) else {
            await refreshNotificationFeed()
            return
        }
    }

    /// Marks every currently unread notification read in wire-safe batches.
    public func markAllNotificationsRead() async {
        let batches = notificationFeed.unreadIDBatches()
        guard !batches.isEmpty else { return }
        notificationFeed.markRead(batches.joined())
        for batch in batches {
            guard await sendNotificationFeedMutation(method: "notification.dismiss", ids: batch) else {
                await refreshNotificationFeed()
                return
            }
        }
    }

    /// Marks a feed item read and navigates to its current workspace and terminal.
    /// - Parameter item: The immutable feed item snapshot selected by the user.
    public func openNotificationFeedItem(_ item: MobileNotificationFeedItem) async {
        await markNotificationsRead(ids: [item.id])
        guard let workspaceID = workspaceID(
            matchingRemoteWorkspaceID: item.workspaceID.uuidString,
            macDeviceID: foregroundMacDeviceID
        ) else { return }
        navigateToWorkspaceForDeeplink(workspaceID)
        if let surfaceID = item.surfaceID {
            selectTerminal(MobileTerminalPreview.ID(rawValue: surfaceID.uuidString))
        }
    }

    private func performNotificationFeedRefresh() async {
        guard let client = remoteClient, connectionState == .connected else { return }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "notification.list",
                params: ["limit": 500]
            )
            let data = try await client.sendRequest(request)
            guard remoteClient === client else { return }
            let response = try MobileNotificationListResponse.decode(data)
            notificationFeed.applyList(response)
            applyAuthoritativeUnreadBadge(response.unreadCount)
        } catch {
            notificationFeedLog.error(
                "notification list failed error=\(String(describing: error), privacy: .private)"
            )
        }
    }

    private func sendNotificationFeedMutation(method: String, ids: [UUID]) async -> Bool {
        guard ids.count <= 256, let client = remoteClient, connectionState == .connected else {
            return false
        }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: method,
                params: ["notification_ids": ids.map(\.uuidString)]
            )
            _ = try await client.sendRequest(request)
            return remoteClient === client
        } catch {
            notificationFeedLog.error(
                "notification mutation failed method=\(method, privacy: .public) error=\(String(describing: error), privacy: .private)"
            )
            return false
        }
    }
}
