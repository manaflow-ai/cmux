internal import CmuxMobileRPC
internal import Foundation
internal import OSLog

private let mobileNotificationsFeedLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-notifications-feed"
)
private let notificationsFeedCapability = "notifications.feed.v1"

extension MobileShellComposite {
    /// Token returned when the feed locally marks notification rows read before
    /// the Mac confirms the workspace read-state mutation.
    public struct OptimisticNotificationReadClaim: Sendable {
        fileprivate let generation: UInt64
        fileprivate let previousNotifications: [MobileNotificationPreview]
    }

    /// Whether the Mac supports the mobile notification feed RPC.
    public var supportsNotificationsFeed: Bool { supportedHostCapabilities.contains(notificationsFeedCapability) }

    /// Optimistically mark a workspace's feed rows as read and claim the current
    /// notification refresh generation. Finishing the claim only rolls back while
    /// this generation is still current, so a newer Mac-authored refresh cannot be
    /// overwritten by the stale pre-tap snapshot.
    public func beginOptimisticNotificationRead(forWorkspace workspaceID: String) -> OptimisticNotificationReadClaim {
        notificationFeedRefreshGeneration &+= 1
        let generation = notificationFeedRefreshGeneration
        notificationFeedRefreshTask?.cancel()
        notificationFeedRefreshTask = nil
        let previousNotifications = notificationsStore.notifications
        notificationsStore.markReadLocally(forWorkspace: workspaceID)
        return OptimisticNotificationReadClaim(
            generation: generation,
            previousNotifications: previousNotifications
        )
    }

    /// Reconcile a previously claimed optimistic feed read against the Mac.
    ///
    /// If the workspace mutation succeeded, this fetches the authoritative feed
    /// snapshot for the claim's generation. If that fetch fails and no newer feed
    /// refresh has superseded the claim, the previous snapshot is restored.
    public func finishOptimisticNotificationRead(
        _ claim: OptimisticNotificationReadClaim,
        mutationSucceeded: Bool
    ) async {
        let didRefresh: Bool
        if mutationSucceeded {
            didRefresh = await refreshNotifications(generation: claim.generation)
        } else {
            didRefresh = false
        }
        guard !didRefresh, notificationFeedRefreshGeneration == claim.generation else { return }
        notificationsStore.apply(claim.previousNotifications)
    }

    func invalidateNotificationFeedRefreshes() {
        notificationFeedRefreshGeneration &+= 1
        notificationFeedRefreshTask?.cancel()
        notificationFeedRefreshTask = nil
    }

    /// Refetch the notification feed from the connected Mac.
    @discardableResult
    public func refreshNotifications() async -> Bool {
        invalidateNotificationFeedRefreshes()
        let generation = notificationFeedRefreshGeneration
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
        invalidateNotificationFeedRefreshes()
        let generation = notificationFeedRefreshGeneration
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
