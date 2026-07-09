import CmuxSettings
import AppKit
import Combine
import Foundation
import CmuxAppKitSupportUI
import CmuxNotifications

@MainActor
final class MenuBarExtraController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu(title: "cmux")
    private let notificationStore: TerminalNotificationStore
    private let onShowGlobalSearch: (NSStatusBarButton, (() -> Void)?) -> Void
    private let onShowMainWindow: () -> Void
    private let onShowNotifications: () -> Void
    private let onOpenNotification: (TerminalNotification) -> Void
    private let onJumpToLatestUnread: () -> Void
    private let onOpenTaskManager: () -> Void
    private let onCheckForUpdates: () -> Void
    private let onOpenPreferences: () -> Void
    private let onQuitApp: () -> Void
    private var notificationMenuSnapshotCancellable: AnyCancellable?
    private let buildHintTitle: String?

    private let stateHintItem = NSMenuItem(title: String(localized: "statusMenu.noUnread", defaultValue: "No unread notifications"), action: nil, keyEquivalent: "")
    private let buildHintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let globalSearchItem = NSMenuItem(title: String(localized: "statusMenu.searchAllWindows", defaultValue: "Search All Windows..."), action: nil, keyEquivalent: "")
    private let showMainWindowItem = NSMenuItem(title: String(localized: "statusMenu.showCmux", defaultValue: "Show cmux"), action: nil, keyEquivalent: "")
    private let taskManagerItem = NSMenuItem(title: String(localized: "statusMenu.taskManager", defaultValue: "Task Manager..."), action: nil, keyEquivalent: "")
    private let notificationListSeparator = NSMenuItem.separator()
    private let notificationSectionSeparator = NSMenuItem.separator()
    private let showNotificationsItem = NSMenuItem(title: String(localized: "statusMenu.showNotifications", defaultValue: "Show Notifications"), action: nil, keyEquivalent: "")
    private let jumpToUnreadItem = NSMenuItem(title: String(localized: "statusMenu.jumpToLatestUnread", defaultValue: "Jump to Latest Unread"), action: nil, keyEquivalent: "")
    private let markAllReadItem = NSMenuItem(title: String(localized: "statusMenu.markAllRead", defaultValue: "Mark All Read"), action: nil, keyEquivalent: "")
    private let clearAllItem = NSMenuItem(title: String(localized: "statusMenu.clearAll", defaultValue: "Clear All"), action: nil, keyEquivalent: "")
    private let checkForUpdatesItem = NSMenuItem(title: String(localized: "menu.checkForUpdates", defaultValue: "Check for Updates…"), action: nil, keyEquivalent: "")
    private let preferencesItem = NSMenuItem(title: String(localized: "menu.preferences", defaultValue: "Preferences…"), action: nil, keyEquivalent: "")
    private let quitItem = NSMenuItem(title: String(localized: "menu.quitCmux", defaultValue: "Quit cmux"), action: nil, keyEquivalent: "")

    private var notificationItems: [NSMenuItem] = []
    init(
        notificationStore: TerminalNotificationStore,
        onShowGlobalSearch: @escaping (NSStatusBarButton, (() -> Void)?) -> Void,
        onShowMainWindow: @escaping () -> Void,
        onShowNotifications: @escaping () -> Void,
        onOpenNotification: @escaping (TerminalNotification) -> Void,
        onJumpToLatestUnread: @escaping () -> Void,
        onOpenTaskManager: @escaping () -> Void,
        onCheckForUpdates: @escaping () -> Void,
        onOpenPreferences: @escaping () -> Void,
        onQuitApp: @escaping () -> Void
    ) {
        self.notificationStore = notificationStore
        self.onShowGlobalSearch = onShowGlobalSearch
        self.onShowMainWindow = onShowMainWindow
        self.onShowNotifications = onShowNotifications
        self.onOpenNotification = onOpenNotification
        self.onJumpToLatestUnread = onJumpToLatestUnread
        self.onOpenTaskManager = onOpenTaskManager
        self.onCheckForUpdates = onCheckForUpdates
        self.onOpenPreferences = onOpenPreferences
        self.onQuitApp = onQuitApp
        self.buildHintTitle = MenuBarBuildHintFormatter.menuTitle()
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        buildMenu()
        statusItem.menu = menu
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.image = NSImage.cmuxMenuBarStatusIcon(unreadCount: 0)
            button.toolTip = "cmux"
        }

        notificationMenuSnapshotCancellable = notificationStore.$notificationMenuSnapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.refreshUI(snapshot: snapshot)
            }

        refreshUI()
    }

    private func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self

        stateHintItem.isEnabled = false
        menu.addItem(stateHintItem)
        if let buildHintTitle {
            buildHintItem.title = buildHintTitle
            buildHintItem.isEnabled = false
            menu.addItem(buildHintItem)
        }

        menu.addItem(.separator())

        globalSearchItem.target = self
        globalSearchItem.action = #selector(globalSearchAction)
        menu.addItem(globalSearchItem)

        showMainWindowItem.target = self
        showMainWindowItem.action = #selector(showMainWindowAction)
        menu.addItem(showMainWindowItem)

        taskManagerItem.target = self
        taskManagerItem.action = #selector(taskManagerAction)
        menu.addItem(taskManagerItem)

        menu.addItem(notificationListSeparator)
        notificationSectionSeparator.isHidden = true
        menu.addItem(notificationSectionSeparator)

        showNotificationsItem.target = self
        showNotificationsItem.action = #selector(showNotificationsAction)
        menu.addItem(showNotificationsItem)

        jumpToUnreadItem.target = self
        jumpToUnreadItem.action = #selector(jumpToUnreadAction)
        menu.addItem(jumpToUnreadItem)

        markAllReadItem.target = self
        markAllReadItem.action = #selector(markAllReadAction)
        menu.addItem(markAllReadItem)

        clearAllItem.target = self
        clearAllItem.action = #selector(clearAllAction)
        menu.addItem(clearAllItem)

        menu.addItem(.separator())

        checkForUpdatesItem.target = self
        checkForUpdatesItem.action = #selector(checkForUpdatesAction)
        menu.addItem(checkForUpdatesItem)

        preferencesItem.target = self
        preferencesItem.action = #selector(preferencesAction)
        menu.addItem(preferencesItem)

        menu.addItem(.separator())

        quitItem.target = self
        quitItem.action = #selector(quitAction)
        menu.addItem(quitItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshUI()
    }

    func refreshForDebugControls() {
        refreshUI()
    }

    func removeFromMenuBar() {
        notificationMenuSnapshotCancellable?.cancel()
        notificationMenuSnapshotCancellable = nil
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func refreshUI() {
        refreshUI(snapshot: notificationStore.notificationMenuSnapshot)
    }

    private func refreshUI(snapshot: NotificationMenuSnapshot) {
        let actualUnreadCount = snapshot.unreadCount

        let displayedUnreadCount: Int
#if DEBUG
        displayedUnreadCount = MenuBarIconDebugSettings.displayedUnreadCount(actualUnreadCount: actualUnreadCount)
#else
        displayedUnreadCount = actualUnreadCount
#endif

        stateHintItem.title = snapshot.stateHintTitle
        showMainWindowItem.isHidden = !MenuBarOnlySettings.shouldShowMainWindowMenuItem()

        applyShortcut(KeyboardShortcutSettings.menuShortcut(for: .globalSearch), to: globalSearchItem)
        applyShortcut(KeyboardShortcutSettings.menuShortcut(for: .showNotifications), to: showNotificationsItem)
        applyShortcut(KeyboardShortcutSettings.menuShortcut(for: .jumpToUnread), to: jumpToUnreadItem)

        jumpToUnreadItem.isEnabled = snapshot.hasUnreadNotifications
        markAllReadItem.isEnabled = snapshot.hasUnreadNotifications
        clearAllItem.isEnabled = snapshot.hasNotifications

        rebuildInlineNotificationItems(recentNotifications: snapshot.recentNotifications)

        if let button = statusItem.button {
            button.image = NSImage.cmuxMenuBarStatusIcon(unreadCount: displayedUnreadCount)
            button.toolTip = displayedUnreadCount == 0
                ? "cmux"
                : displayedUnreadCount == 1
                    ? "cmux: " + String(localized: "statusMenu.tooltip.unread.one", defaultValue: "1 unread notification")
                    : "cmux: " + String(localized: "statusMenu.tooltip.unread.other", defaultValue: "\(displayedUnreadCount) unread notifications")
        }
    }

    private func applyShortcut(_ shortcut: StoredShortcut, to item: NSMenuItem) {
        guard let keyEquivalent = shortcut.menuItemKeyEquivalent else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        item.keyEquivalent = keyEquivalent
        item.keyEquivalentModifierMask = shortcut.modifierFlags
    }

    private func rebuildInlineNotificationItems(recentNotifications: [TerminalNotification]) {
        for item in notificationItems {
            menu.removeItem(item)
        }
        notificationItems.removeAll(keepingCapacity: true)

        notificationListSeparator.isHidden = recentNotifications.isEmpty
        notificationSectionSeparator.isHidden = recentNotifications.isEmpty
        guard !recentNotifications.isEmpty else { return }

        let insertionIndex = menu.index(of: showNotificationsItem)
        guard insertionIndex >= 0 else { return }

        for (offset, notification) in recentNotifications.enumerated() {
            let tabTitle = AppDelegate.shared?.tabTitle(for: notification.tabId)
            let item = makeNotificationItem(notification: notification, tabTitle: tabTitle)
            menu.insertItem(item, at: insertionIndex + offset)
            notificationItems.append(item)
        }
    }

    private func makeNotificationItem(notification: TerminalNotification, tabTitle: String?) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(openNotificationItemAction(_:)), keyEquivalent: "")
        item.target = self
        let line = MenuBarNotificationLine(notification: notification, tabTitle: tabTitle)
        item.attributedTitle = line.attributedTitle
        item.toolTip = line.tooltip
        item.representedObject = NotificationMenuItemPayload(notification: notification)
        return item
    }

    @objc private func openNotificationItemAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? NotificationMenuItemPayload else { return }
        onOpenNotification(payload.notification)
    }

    @discardableResult
    func toggleGlobalSearchPalette(onDismiss: (() -> Void)? = nil) -> Bool {
        guard let button = statusItem.button else { return false }
        onShowGlobalSearch(button, onDismiss)
        return true
    }

    @objc private func globalSearchAction() {
        toggleGlobalSearchPalette()
    }

    @objc private func showMainWindowAction() {
        onShowMainWindow()
    }

    @objc private func showNotificationsAction() {
        onShowNotifications()
    }

    @objc private func jumpToUnreadAction() {
        onJumpToLatestUnread()
    }

    @objc private func taskManagerAction() {
        onOpenTaskManager()
    }

    @objc private func markAllReadAction() {
        notificationStore.markAllRead()
    }

    @objc private func clearAllAction() {
        notificationStore.clearAll()
    }

    @objc private func checkForUpdatesAction() {
        onCheckForUpdates()
    }

    @objc private func preferencesAction() {
        onOpenPreferences()
    }

    @objc private func quitAction() {
        onQuitApp()
    }
}

private final class NotificationMenuItemPayload: NSObject {
    let notification: TerminalNotification

    init(notification: TerminalNotification) {
        self.notification = notification
        super.init()
    }
}

struct NotificationMenuSnapshot: Equatable {
    let unreadCount: Int
    let hasNotifications: Bool
    let recentNotifications: [TerminalNotification]

    var hasUnreadNotifications: Bool {
        unreadCount > 0
    }

    var stateHintTitle: String {
        NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount: unreadCount)
    }
}

enum NotificationMenuSnapshotBuilder {
    static let defaultInlineNotificationLimit = 6

    static func make(
        notifications: [TerminalNotification],
        workspaceUnreadIndicatorCount: Int = 0,
        maxInlineNotificationItems: Int = defaultInlineNotificationLimit
    ) -> NotificationMenuSnapshot {
        let unreadCount = notifications.reduce(into: 0) { count, notification in
            if !notification.isRead {
                count += 1
            }
        } + workspaceUnreadIndicatorCount

        let inlineLimit = max(0, maxInlineNotificationItems)
        return NotificationMenuSnapshot(
            unreadCount: unreadCount,
            hasNotifications: !notifications.isEmpty || workspaceUnreadIndicatorCount > 0,
            recentNotifications: Array(notifications.prefix(inlineLimit))
        )
    }

    static func stateHintTitle(unreadCount: Int) -> String {
        switch unreadCount {
        case 0:
            return String(localized: "statusMenu.noUnread", defaultValue: "No unread notifications")
        case 1:
            return String(localized: "statusMenu.unreadCount.one", defaultValue: "1 unread notification")
        default:
            return String(localized: "statusMenu.unreadCount.other", defaultValue: "\(unreadCount) unread notifications")
        }
    }
}

enum MenuBarBuildHintFormatter {
    static func menuTitle(
        appName: String = defaultAppName(),
        isDebugBuild: Bool = _isDebugAssertConfiguration()
    ) -> String? {
        guard isDebugBuild else { return nil }
        let normalized = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "cmux DEV"
        guard normalized.hasPrefix(prefix) else { return "Build: DEV" }

        let suffix = String(normalized.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if suffix.isEmpty {
            return "Build: DEV (untagged)"
        }
        return "Build Tag: \(suffix)"
    }

    private static func defaultAppName() -> String {
        let bundle = Bundle.main
        if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty {
            return displayName
        }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
            return name
        }
        return ProcessInfo.processInfo.processName
    }
}

enum MenuBarExtraSettings {
    static let showInMenuBarKey = "showMenuBarExtra"
    static let defaultShowInMenuBar = true

    static func showsMenuBarExtra(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: showInMenuBarKey) == nil {
            return defaultShowInMenuBar
        }
        return defaults.bool(forKey: showInMenuBarKey)
    }

    static func shouldInstallMenuBarExtra(defaults: UserDefaults = .standard) -> Bool {
        MenuBarOnlySettings.isEnabled(defaults: defaults) || showsMenuBarExtra(defaults: defaults)
    }
}

enum MenuBarOnlySettings {
    static let menuBarOnlyKey = "menuBarOnly"
    static let explicitEnableKey = "menuBarOnlyExplicitlyEnabled.v1"
    static let defaultMenuBarOnly = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: menuBarOnlyKey) != nil, defaults.bool(forKey: menuBarOnlyKey) else { return defaultMenuBarOnly }
        if defaults.object(forKey: explicitEnableKey) != nil {
            return defaults.bool(forKey: explicitEnableKey)
        }
        return !legacyCommandPaletteOneShotLikelyEnabledMenuBarOnly(defaults: defaults)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: menuBarOnlyKey)
        defaults.set(enabled, forKey: explicitEnableKey)
    }

    static func activationPolicy(defaults: UserDefaults = .standard) -> NSApplication.ActivationPolicy {
        isEnabled(defaults: defaults) ? .accessory : .regular
    }

    static func shouldShowMainWindowMenuItem(defaults: UserDefaults = .standard) -> Bool {
        isEnabled(defaults: defaults)
    }

    static func applyActivationPolicy(defaults: UserDefaults = .standard, application: NSApplication = .shared) {
        let targetPolicy = activationPolicy(defaults: defaults)
        guard application.activationPolicy() != targetPolicy else { return }
        application.setActivationPolicy(targetPolicy)
    }
}

