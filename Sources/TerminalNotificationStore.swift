import AppKit
import Foundation
import UserNotifications

enum NotificationBadgeSettings {
    static let dockBadgeEnabledKey = "notificationDockBadgeEnabled"
    static let defaultDockBadgeEnabled = true

    static func isDockBadgeEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: dockBadgeEnabledKey) == nil {
            return defaultDockBadgeEnabled
        }
        return defaults.bool(forKey: dockBadgeEnabledKey)
    }
}

enum TaggedRunBadgeSettings {
    static let environmentKey = "CMUX_TAG"
    private static let maxTagLength = 10

    static func normalizedTag(from env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        normalizedTag(env[environmentKey])
    }

    static func normalizedTag(_ rawTag: String?) -> String? {
        guard var tag = rawTag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty else {
            return nil
        }
        if tag.count > maxTagLength {
            tag = String(tag.prefix(maxTagLength))
        }
        return tag
    }
}

enum AppFocusState {
    static var overrideIsFocused: Bool?

    static func isAppActive() -> Bool {
        if let overrideIsFocused {
            return overrideIsFocused
        }
        return NSApp.isActive
    }

    static func isAppFocused() -> Bool {
        if let overrideIsFocused {
            return overrideIsFocused
        }
        guard NSApp.isActive else { return false }
        guard let keyWindow = NSApp.keyWindow, keyWindow.isKeyWindow else { return false }
        // Only treat the app as "focused" for notification suppression when a main terminal window
        // is key. If Settings/About/debug panels are key, we still want notifications to show.
        if let raw = keyWindow.identifier?.rawValue {
            return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
        }
        return false
    }
}

struct TerminalNotification: Identifiable, Hashable {
    let id: UUID
    let tabId: UUID
    let surfaceId: UUID?
    let title: String
    let subtitle: String
    let body: String
    let createdAt: Date
    var isRead: Bool
}

@MainActor
final class TerminalNotificationStore: ObservableObject {
    private struct TabSurfaceKey: Hashable {
        let tabId: UUID
        let surfaceId: UUID?
    }

    private struct NotificationIndexes {
        var unreadCount = 0
        var unreadCountByTabId: [UUID: Int] = [:]
        var unreadByTabSurface = Set<TabSurfaceKey>()
        var latestUnreadByTabId: [UUID: TerminalNotification] = [:]
        var latestByTabId: [UUID: TerminalNotification] = [:]
    }

    static let shared = TerminalNotificationStore()

    static let categoryIdentifier = "com.cmuxterm.app.userNotification"
    static let actionShowIdentifier = "com.cmuxterm.app.userNotification.show"

    @Published private(set) var notifications: [TerminalNotification] = [] {
        didSet {
            indexes = Self.buildIndexes(for: notifications)
            refreshDockBadge()
        }
    }

    private let center = UNUserNotificationCenter.current()
    private var hasRequestedAuthorization = false
    private var hasPromptedForSettings = false
    private var userDefaultsObserver: NSObjectProtocol?
    private let settingsPromptWindowRetryDelay: TimeInterval = 0.5
    private let settingsPromptWindowRetryLimit = 20
    private var notificationSettingsWindowProvider: () -> NSWindow? = {
        NSApp.keyWindow ?? NSApp.mainWindow
    }
    private var notificationSettingsAlertFactory: () -> NSAlert = {
        NSAlert()
    }
    private var notificationSettingsScheduler: (_ delay: TimeInterval, _ block: @escaping () -> Void) -> Void = {
        delay,
        block in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            block()
        }
    }
    private var notificationSettingsURLOpener: (URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }
    private var indexes = NotificationIndexes()

    private init() {
        indexes = Self.buildIndexes(for: notifications)
        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshDockBadge()
        }
        refreshDockBadge()
    }

    deinit {
        if let userDefaultsObserver {
            NotificationCenter.default.removeObserver(userDefaultsObserver)
        }
    }

    static func dockBadgeLabel(unreadCount: Int, isEnabled: Bool, runTag: String? = nil) -> String? {
        let unreadLabel: String? = {
            guard isEnabled, unreadCount > 0 else { return nil }
            if unreadCount > 99 {
                return "99+"
            }
            return String(unreadCount)
        }()

        if let tag = TaggedRunBadgeSettings.normalizedTag(runTag) {
            if let unreadLabel {
                return "\(tag):\(unreadLabel)"
            }
            return tag
        }

        return unreadLabel
    }

    var unreadCount: Int {
        indexes.unreadCount
    }

    func unreadCount(forTabId tabId: UUID) -> Int {
        indexes.unreadCountByTabId[tabId] ?? 0
    }

    func hasUnreadNotification(forTabId tabId: UUID, surfaceId: UUID?) -> Bool {
        indexes.unreadByTabSurface.contains(TabSurfaceKey(tabId: tabId, surfaceId: surfaceId))
    }

    func latestNotification(forTabId tabId: UUID) -> TerminalNotification? {
        indexes.latestUnreadByTabId[tabId] ?? indexes.latestByTabId[tabId]
    }

    func addNotification(tabId: UUID, surfaceId: UUID?, title: String, subtitle: String, body: String) {
        var updated = notifications
        var idsToClear: [String] = []
        updated.removeAll { existing in
            guard existing.tabId == tabId, existing.surfaceId == surfaceId else { return false }
            idsToClear.append(existing.id.uuidString)
            return true
        }

        let isActiveTab = AppDelegate.shared?.tabManager?.selectedTabId == tabId
        let focusedSurfaceId = AppDelegate.shared?.tabManager?.focusedSurfaceId(for: tabId)
        let isFocusedSurface = surfaceId == nil || focusedSurfaceId == surfaceId
        let isFocusedPanel = isActiveTab && isFocusedSurface
        let isAppFocused = AppFocusState.isAppFocused()
        if isAppFocused && isFocusedPanel {
            if !idsToClear.isEmpty {
                notifications = updated
                center.removeDeliveredNotifications(withIdentifiers: idsToClear)
                center.removePendingNotificationRequests(withIdentifiers: idsToClear)
            }
            return
        }

        if WorkspaceAutoReorderSettings.isEnabled() {
            AppDelegate.shared?.tabManager?.moveTabToTop(tabId)
        }

        let notification = TerminalNotification(
            id: UUID(),
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            subtitle: subtitle,
            body: body,
            createdAt: Date(),
            isRead: false
        )
        updated.insert(notification, at: 0)
        notifications = updated
        if !idsToClear.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: idsToClear)
            center.removePendingNotificationRequests(withIdentifiers: idsToClear)
        }
        scheduleUserNotification(notification)
    }

    func markRead(id: UUID) {
        var updated = notifications
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        guard !updated[index].isRead else { return }
        updated[index].isRead = true
        notifications = updated
        center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }

    func markRead(forTabId tabId: UUID) {
        var updated = notifications
        var idsToClear: [String] = []
        for index in updated.indices {
            if updated[index].tabId == tabId && !updated[index].isRead {
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            notifications = updated
            center.removeDeliveredNotifications(withIdentifiers: idsToClear)
        }
    }

    func markRead(forTabId tabId: UUID, surfaceId: UUID?) {
        var updated = notifications
        var idsToClear: [String] = []
        for index in updated.indices {
            if updated[index].tabId == tabId,
               updated[index].surfaceId == surfaceId,
               !updated[index].isRead {
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            notifications = updated
            center.removeDeliveredNotifications(withIdentifiers: idsToClear)
            center.removePendingNotificationRequests(withIdentifiers: idsToClear)
        }
    }

    func markUnread(forTabId tabId: UUID) {
        var updated = notifications
        var didChange = false
        for index in updated.indices {
            if updated[index].tabId == tabId, updated[index].isRead {
                updated[index].isRead = false
                didChange = true
            }
        }
        if didChange {
            notifications = updated
        }
    }

    func markAllRead() {
        var updated = notifications
        var idsToClear: [String] = []
        for index in updated.indices {
            if !updated[index].isRead {
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            notifications = updated
            center.removeDeliveredNotifications(withIdentifiers: idsToClear)
            center.removePendingNotificationRequests(withIdentifiers: idsToClear)
        }
    }

    func remove(id: UUID) {
        var updated = notifications
        let originalCount = updated.count
        updated.removeAll { $0.id == id }
        guard updated.count != originalCount else { return }
        notifications = updated
        center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }

    func clearAll() {
        guard !notifications.isEmpty else { return }
        let ids = notifications.map { $0.id.uuidString }
        notifications.removeAll()
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    func clearNotifications(forTabId tabId: UUID, surfaceId: UUID?) {
        var updated: [TerminalNotification] = []
        updated.reserveCapacity(notifications.count)
        var idsToClear: [String] = []
        for notification in notifications {
            if notification.tabId == tabId, notification.surfaceId == surfaceId {
                idsToClear.append(notification.id.uuidString)
            } else {
                updated.append(notification)
            }
        }
        guard !idsToClear.isEmpty else { return }
        notifications = updated
        center.removeDeliveredNotifications(withIdentifiers: idsToClear)
        center.removePendingNotificationRequests(withIdentifiers: idsToClear)
    }

    func clearNotifications(forTabId tabId: UUID) {
        var updated: [TerminalNotification] = []
        updated.reserveCapacity(notifications.count)
        var idsToClear: [String] = []
        for notification in notifications {
            if notification.tabId == tabId {
                idsToClear.append(notification.id.uuidString)
            } else {
                updated.append(notification)
            }
        }
        guard !idsToClear.isEmpty else { return }
        notifications = updated
        center.removeDeliveredNotifications(withIdentifiers: idsToClear)
        center.removePendingNotificationRequests(withIdentifiers: idsToClear)
    }

    private func scheduleUserNotification(_ notification: TerminalNotification) {
        ensureAuthorization { [weak self] authorized in
            guard let self, authorized else { return }

            let content = UNMutableNotificationContent()
            let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? "cmux"
            content.title = notification.title.isEmpty ? appName : notification.title
            content.subtitle = notification.subtitle
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
            self.presentNotificationSettingsPrompt(attempt: 0)
        }
    }

    private func presentNotificationSettingsPrompt(attempt: Int) {
        guard let window = notificationSettingsWindowProvider() else {
            guard attempt < settingsPromptWindowRetryLimit else {
                // If no window is available after retries, allow a future denied callback
                // to prompt again when the app has a key/main window.
                hasPromptedForSettings = false
                return
            }
            notificationSettingsScheduler(settingsPromptWindowRetryDelay) { [weak self] in
                self?.presentNotificationSettingsPrompt(attempt: attempt + 1)
            }
            return
        }

        let alert = notificationSettingsAlertFactory()
        alert.messageText = "Enable Notifications for cmux"
        alert.informativeText = "Notifications are disabled for cmux. Enable them in System Settings to see alerts."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else {
                return
            }
            self?.notificationSettingsURLOpener(url)
        }
    }

    private static func buildIndexes(for notifications: [TerminalNotification]) -> NotificationIndexes {
        var indexes = NotificationIndexes()
        for notification in notifications {
            if indexes.latestByTabId[notification.tabId] == nil {
                indexes.latestByTabId[notification.tabId] = notification
            }
            guard !notification.isRead else { continue }
            indexes.unreadCount += 1
            indexes.unreadCountByTabId[notification.tabId, default: 0] += 1
            indexes.unreadByTabSurface.insert(
                TabSurfaceKey(tabId: notification.tabId, surfaceId: notification.surfaceId)
            )
            if indexes.latestUnreadByTabId[notification.tabId] == nil {
                indexes.latestUnreadByTabId[notification.tabId] = notification
            }
        }
        return indexes
    }

#if DEBUG
    func configureNotificationSettingsPromptHooksForTesting(
        windowProvider: @escaping () -> NSWindow?,
        alertFactory: @escaping () -> NSAlert,
        scheduler: @escaping (_ delay: TimeInterval, _ block: @escaping () -> Void) -> Void,
        urlOpener: @escaping (URL) -> Void
    ) {
        notificationSettingsWindowProvider = windowProvider
        notificationSettingsAlertFactory = alertFactory
        notificationSettingsScheduler = scheduler
        notificationSettingsURLOpener = urlOpener
        hasPromptedForSettings = false
    }

    func resetNotificationSettingsPromptHooksForTesting() {
        notificationSettingsWindowProvider = { NSApp.keyWindow ?? NSApp.mainWindow }
        notificationSettingsAlertFactory = { NSAlert() }
        notificationSettingsScheduler = { delay, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                block()
            }
        }
        notificationSettingsURLOpener = { url in
            NSWorkspace.shared.open(url)
        }
        hasPromptedForSettings = false
    }

    func promptToEnableNotificationsForTesting() {
        promptToEnableNotifications()
    }

    func replaceNotificationsForTesting(_ notifications: [TerminalNotification]) {
        self.notifications = notifications
    }
#endif

    private func refreshDockBadge() {
        let label = Self.dockBadgeLabel(
            unreadCount: unreadCount,
            isEnabled: NotificationBadgeSettings.isDockBadgeEnabled(),
            runTag: TaggedRunBadgeSettings.normalizedTag()
        )
        NSApp?.dockTile.badgeLabel = label
    }
}
