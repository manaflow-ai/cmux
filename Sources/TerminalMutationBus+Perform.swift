extension TerminalMutationBus {
    @MainActor
    func perform(_ batch: [TerminalSocketMutationEntry]) {
        for entry in batch {
            switch entry.mutation {
            case .deliverNotification(let notification):
#if DEBUG
                cmuxDebugLog(
                    "notification.queue.perform seq=\(entry.sequence) workspace=\(notification.key.tabId.uuidString.prefix(8)) surface=\(notification.key.surfaceId?.uuidString.prefix(8) ?? "nil") titleLen=\(notification.title.count) subtitleLen=\(notification.subtitle.count) bodyLen=\(notification.body.count)"
                )
#endif
                TerminalNotificationStore.shared.deliverQueuedNotification(
                    claimedTabId: notification.key.tabId,
                    surfaceId: notification.key.surfaceId,
                    title: notification.title,
                    subtitle: notification.subtitle,
                    body: notification.body,
                    id: notification.id,
                    acceptedAt: notification.acceptedAt,
                    notificationGeneration: entry.notificationGeneration ?? 0,
                    allowWorkspaceFallbackForValidatedSurface: notification.allowWorkspaceFallbackForValidatedSurface
                )
            case .clearAllNotifications(let boundary):
                TerminalNotificationStore.shared.clearAll(
                    discardQueuedNotifications: false,
                    throughNotificationGeneration: boundary
                )
            case .clearNotificationsForTab(let tabId, let boundary):
                TerminalNotificationStore.shared.clearNotifications(
                    forTabId: tabId,
                    discardQueuedNotifications: false,
                    throughNotificationGeneration: boundary
                )
            case .clearNotificationsForSurface(let tabId, let surfaceId, let boundary):
                TerminalNotificationStore.shared.clearNotifications(
                    forTabId: tabId,
                    surfaceId: surfaceId,
                    discardQueuedNotifications: false,
                    throughNotificationGeneration: boundary
                )
            case .perform(let mutation):
                mutation()
            }
        }
    }
}
