import Foundation

extension TerminalNotificationStore {
    func resolvedWorkspaceTitle(forTabId tabId: UUID) -> String? {
        guard let title = AppDelegate.shared?.tabTitle(for: tabId)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty else {
            return nil
        }
        return title
    }

    func notificationAppName() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "cmux"
    }

    func bannerContent(for notification: TerminalNotification) -> NotificationBannerContent {
        composeNotificationBannerContent(
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body,
            agentId: notification.agentId,
            workspaceTitle: notification.workspaceTitle,
            appName: notificationAppName()
        )
    }
}
