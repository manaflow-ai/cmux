import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static var shared: AppDelegate?

    weak var tabManager: TabManager?
    weak var notificationStore: TerminalNotificationStore?

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureUserNotifications()
    }

    func configure(tabManager: TabManager, notificationStore: TerminalNotificationStore) {
        self.tabManager = tabManager
        self.notificationStore = notificationStore
    }

    private func configureUserNotifications() {
        let actions = [
            UNNotificationAction(
                identifier: TerminalNotificationStore.actionShowIdentifier,
                title: "Show"
            )
        ]

        let category = UNNotificationCategory(
            identifier: TerminalNotificationStore.categoryIdentifier,
            actions: actions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([category])
        center.delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleNotificationResponse(response)
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let shouldPresent = shouldPresentNotification(notification)
        let options: UNNotificationPresentationOptions = shouldPresent ? [.banner, .sound] : []
        completionHandler(options)
    }

    private func handleNotificationResponse(_ response: UNNotificationResponse) {
        guard let tabIdString = response.notification.request.content.userInfo["tabId"] as? String,
              let tabId = UUID(uuidString: tabIdString) else {
            return
        }

        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier, TerminalNotificationStore.actionShowIdentifier:
            DispatchQueue.main.async {
                if let notificationId = UUID(uuidString: response.notification.request.identifier) {
                    self.notificationStore?.markRead(id: notificationId)
                } else if let notificationIdString = response.notification.request.content.userInfo["notificationId"] as? String,
                          let notificationId = UUID(uuidString: notificationIdString) {
                    self.notificationStore?.markRead(id: notificationId)
                }
                self.tabManager?.focusTab(tabId)
            }
        case UNNotificationDismissActionIdentifier:
            DispatchQueue.main.async {
                if let notificationId = UUID(uuidString: response.notification.request.identifier) {
                    self.notificationStore?.markRead(id: notificationId)
                } else if let notificationIdString = response.notification.request.content.userInfo["notificationId"] as? String,
                          let notificationId = UUID(uuidString: notificationIdString) {
                    self.notificationStore?.markRead(id: notificationId)
                }
            }
        default:
            break
        }
    }

    private func shouldPresentNotification(_ notification: UNNotification) -> Bool {
        guard let tabManager else { return true }
        guard let tabIdString = notification.request.content.userInfo["tabId"] as? String,
              let tabId = UUID(uuidString: tabIdString) else {
            return true
        }

        let isAppActive = NSApp.isActive
        let isTabActive = tabManager.selectedTabId == tabId
        let isKeyWindow = NSApp.keyWindow?.isKeyWindow ?? false

        if isAppActive && isTabActive && isKeyWindow {
            return false
        }

        return true
    }
}
