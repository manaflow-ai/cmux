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
    static let shared = TerminalNotificationStore()

    static let categoryIdentifier = "com.cmuxterm.app.userNotification"
    static let actionShowIdentifier = "com.cmuxterm.app.userNotification.show"

    @Published private(set) var notifications: [TerminalNotification] = [] {
        didSet {
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

    private init() {
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

    func addNotification(tabId: UUID, surfaceId: UUID?, title: String, subtitle: String, body: String) {
        clearNotifications(forTabId: tabId, surfaceId: surfaceId)

        let isActiveTab = AppDelegate.shared?.tabManager?.selectedTabId == tabId
        let focusedSurfaceId = AppDelegate.shared?.tabManager?.focusedSurfaceId(for: tabId)
        let isFocusedSurface = surfaceId == nil || focusedSurfaceId == surfaceId
        let isFocusedPanel = isActiveTab && isFocusedSurface
        let isAppFocused = AppFocusState.isAppFocused()
        if isAppFocused && isFocusedPanel {
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

    func markAllRead() {
        var idsToClear: [String] = []
        for index in notifications.indices {
            if !notifications[index].isRead {
                notifications[index].isRead = true
                idsToClear.append(notifications[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: idsToClear)
            center.removePendingNotificationRequests(withIdentifiers: idsToClear)
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

    func clearNotifications(forTabId tabId: UUID) {
        let ids = notifications
            .filter { $0.tabId == tabId }
            .map { $0.id.uuidString }
        notifications.removeAll { $0.tabId == tabId }
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
