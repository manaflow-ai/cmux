internal import CmuxMobileRPC
internal import Foundation
internal import OSLog

private let mobileNotificationsFeedLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-notifications-feed"
)
private let notificationsFeedCapability = "notifications.feed.v1"

extension MobileShellComposite {
    /// Whether the Mac supports the mobile notification feed RPC.
    public var supportsNotificationsFeed: Bool { supportedHostCapabilities.contains(notificationsFeedCapability) }

    /// Refetch the notification feed from the connected Mac.
    @discardableResult
    public func refreshNotifications() async -> Bool {
        notificationFeedRefreshGeneration &+= 1
        let generation = notificationFeedRefreshGeneration
        notificationFeedRefreshTask?.cancel()
        notificationFeedRefreshTask = nil
        return await refreshNotifications(generation: generation)
    }

    @discardableResult
    private func refreshNotifications(generation: UInt64?) async -> Bool {
        guard supportsNotificationsFeed, connectionState == .connected, let client = remoteClient else {
            notificationsStore.apply([])
            return false
        }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.notifications.list",
                params: [:]
            )
            let result = try await client.sendRequest(request)
            let response = try MobileNotificationsListResponse.decode(result)
            guard remoteClient === client, connectionState == .connected else { return false }
            if let generation, generation != notificationFeedRefreshGeneration { return false }
            notificationsStore.apply(response.previews())
            return true
        } catch {
            guard !Task.isCancelled,
                  remoteClient === client,
                  connectionState == .connected else { return false }
            if let generation, generation != notificationFeedRefreshGeneration { return false }
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return false }
            mobileNotificationsFeedLog.error("notification feed refresh failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func scheduleNotificationsRefreshFromEvent() {
        guard supportsNotificationsFeed, remoteClient != nil else { return }
        notificationFeedRefreshGeneration &+= 1
        let generation = notificationFeedRefreshGeneration
        notificationFeedRefreshTask?.cancel()
        notificationFeedRefreshTask = Task { @MainActor [weak self] in
            defer {
                if self?.notificationFeedRefreshGeneration == generation {
                    self?.notificationFeedRefreshTask = nil
                }
            }
            await self?.refreshNotifications(generation: generation)
        }
    }
}
