import AppKit
import Foundation
import UserNotifications

enum AppFocusState {
    static var overrideIsFocused: Bool?

    static func isAppFocused() -> Bool {
        if let overrideIsFocused {
            return overrideIsFocused
        }
        return NSApp.isActive && (NSApp.keyWindow?.isKeyWindow ?? false)
    }
}

struct TerminalNotification: Identifiable, Hashable {
    let id: UUID
    let tabId: UUID
    let surfaceId: UUID?
    let title: String
    let body: String
    let createdAt: Date
    var isRead: Bool
}

final class TerminalNotificationStore: ObservableObject {
    static let shared = TerminalNotificationStore()

    static let categoryIdentifier = "com.cmuxterm.app.userNotification"
    static let actionShowIdentifier = "com.cmuxterm.app.userNotification.show"

    @Published private(set) var notifications: [TerminalNotification] = []

    private let center = UNUserNotificationCenter.current()
    private var hasRequestedAuthorization = false
    private var hasPromptedForSettings = false

    private init() {}

    var unreadCount: Int {
        notifications.filter { !$0.isRead }.count
    }

    func unreadCount(forTabId tabId: UUID) -> Int {
        notifications.filter { $0.tabId == tabId && !$0.isRead }.count
    }

    func hasUnreadNotification(forTabId tabId: UUID, surfaceId: UUID?) -> Bool {
        notifications.contains { $0.tabId == tabId && $0.surfaceId == surfaceId && !$0.isRead }
    }

    func latestNotification(forTabId tabId: UUID) -> TerminalNotification? {
        if let unread = notifications.first(where: { $0.tabId == tabId && !$0.isRead }) {
            return unread
        }
        return notifications.first(where: { $0.tabId == tabId })
    }

    func addNotification(tabId: UUID, surfaceId: UUID?, title: String, body: String) {
        clearNotifications(forTabId: tabId, surfaceId: surfaceId)

        let isActiveTab = AppDelegate.shared?.tabManager?.selectedTabId == tabId
        let focusedSurfaceId = AppDelegate.shared?.tabManager?.focusedSurfaceId(for: tabId)
        let isFocusedSurface = surfaceId == nil || focusedSurfaceId == surfaceId
        let isFocusedPanel = isActiveTab && isFocusedSurface
        let isAppFocused = AppFocusState.isAppFocused()
        if isAppFocused && isFocusedPanel {
            return
        }

        let notification = TerminalNotification(
            id: UUID(),
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            body: body,
            createdAt: Date(),
            isRead: false
        )
        notifications.insert(notification, at: 0)
        scheduleUserNotification(notification)
    }

    func markRead(id: UUID) {
        guard let index = notifications.firstIndex(where: { $0.id == id }) else { return }
        if notifications[index].isRead { return }
        notifications[index].isRead = true
        center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }

    func markRead(forTabId tabId: UUID) {
        var idsToClear: [String] = []
        for index in notifications.indices {
            if notifications[index].tabId == tabId && !notifications[index].isRead {
                notifications[index].isRead = true
                idsToClear.append(notifications[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: idsToClear)
        }
    }

    func markRead(forTabId tabId: UUID, surfaceId: UUID?) {
        var idsToClear: [String] = []
        for index in notifications.indices {
            if notifications[index].tabId == tabId,
               notifications[index].surfaceId == surfaceId,
               !notifications[index].isRead {
                notifications[index].isRead = true
                idsToClear.append(notifications[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: idsToClear)
            center.removePendingNotificationRequests(withIdentifiers: idsToClear)
        }
    }

    func markUnread(forTabId tabId: UUID) {
        for index in notifications.indices {
            if notifications[index].tabId == tabId {
                notifications[index].isRead = false
            }
        }
    }

    func remove(id: UUID) {
        notifications.removeAll { $0.id == id }
        center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }

    func clearAll() {
        let ids = notifications.map { $0.id.uuidString }
        notifications.removeAll()
        if !ids.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func clearNotifications(forTabId tabId: UUID, surfaceId: UUID?) {
        let ids = notifications
            .filter { $0.tabId == tabId && $0.surfaceId == surfaceId }
            .map { $0.id.uuidString }
        notifications.removeAll { $0.tabId == tabId && $0.surfaceId == surfaceId }
        if !ids.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: ids)
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    private func scheduleUserNotification(_ notification: TerminalNotification) {
        ensureAuthorization { [weak self] authorized in
            guard let self, authorized else { return }

            let content = UNMutableNotificationContent()
            let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? "cmuxterm"
            content.title = appName
            content.subtitle = notification.title
            content.body = notification.body
            content.sound = UNNotificationSound.default
            content.categoryIdentifier = Self.categoryIdentifier
            content.userInfo = [
                "tabId": notification.tabId.uuidString,
                "notificationId": notification.id.uuidString,
            ]
            if let surfaceId = notification.surfaceId {
                content.userInfo["surfaceId"] = surfaceId.uuidString
            }

            let request = UNNotificationRequest(
                identifier: notification.id.uuidString,
                content: content,
                trigger: nil
            )

            self.center.add(request) { error in
                if let error {
                    NSLog("Failed to schedule notification: \(error)")
                }
            }
        }
    }

    private func ensureAuthorization(_ completion: @escaping (Bool) -> Void) {
        center.getNotificationSettings { [weak self] settings in
            guard let self else {
                completion(false)
                return
            }

            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                completion(true)
            case .denied:
                self.promptToEnableNotifications()
                completion(false)
            case .notDetermined:
                self.requestAuthorizationIfNeeded(completion)
            @unknown default:
                completion(false)
            }
        }
    }

    private func requestAuthorizationIfNeeded(_ completion: @escaping (Bool) -> Void) {
        guard !hasRequestedAuthorization else {
            completion(false)
            return
        }
        hasRequestedAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            completion(granted)
        }
    }

    private func promptToEnableNotifications() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.hasPromptedForSettings else { return }
            self.hasPromptedForSettings = true

            let alert = NSAlert()
            alert.messageText = "Enable Notifications for cmuxterm"
            alert.informativeText = "Notifications are disabled for cmuxterm. Enable them in System Settings to see alerts."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Not Now")
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
