import AppKit
import Combine
import CmuxFoundation
import Foundation

@MainActor
final class MenuBarExtraController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu(title: "cmux")
    private let notificationStore: TerminalNotificationStore
    private let caffeineController: CaffeineController
    private let onShowGlobalSearch: (NSStatusBarButton, (() -> Void)?) -> Void
    private let onShowMainWindow: () -> Void
    private let onShowNotifications: () -> Void
    private let onOpenNotification: (TerminalNotification) -> Void
    private let onJumpToLatestUnread: () -> Void
    private let onOpenTaskManager: () -> Void
    private let onToggleSleepyMode: () -> Void
    private let onCheckForUpdates: () -> Void
    private let onOpenPreferences: () -> Void
    private let onQuitApp: () -> Void
    private var notificationMenuSnapshotCancellable: AnyCancellable?
    private var globalFontObserver: NSObjectProtocol?
    private let buildHintTitle: String?

    private let stateHintItem = NSMenuItem(title: String(localized: "statusMenu.noUnread", defaultValue: "No unread notifications"), action: nil, keyEquivalent: "")
    private let buildHintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let globalSearchItem = NSMenuItem(title: String(localized: "statusMenu.searchAllWindows", defaultValue: "Search All Windows..."), action: nil, keyEquivalent: "")
    private let showMainWindowItem = NSMenuItem(title: String(localized: "statusMenu.showCmux", defaultValue: "Show cmux"), action: nil, keyEquivalent: "")
    private let taskManagerItem = NSMenuItem(title: String(localized: "statusMenu.taskManager", defaultValue: "Task Manager..."), action: nil, keyEquivalent: "")
    private let sleepyModeItem = NSMenuItem(title: String(localized: "statusMenu.sleepyMode", defaultValue: "Sleepy Mode"), action: nil, keyEquivalent: "")
    private let caffeineItem = NSMenuItem(title: String(localized: "statusMenu.keepMacAwake", defaultValue: "Keep Mac Awake"), action: nil, keyEquivalent: "")
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
        caffeineController: CaffeineController,
        onShowGlobalSearch: @escaping (NSStatusBarButton, (() -> Void)?) -> Void,
        onShowMainWindow: @escaping () -> Void,
        onShowNotifications: @escaping () -> Void,
        onOpenNotification: @escaping (TerminalNotification) -> Void,
        onJumpToLatestUnread: @escaping () -> Void,
        onOpenTaskManager: @escaping () -> Void,
        onToggleSleepyMode: @escaping () -> Void,
        onCheckForUpdates: @escaping () -> Void,
        onOpenPreferences: @escaping () -> Void,
        onQuitApp: @escaping () -> Void
    ) {
        self.notificationStore = notificationStore
        self.caffeineController = caffeineController
        self.onShowGlobalSearch = onShowGlobalSearch
        self.onShowMainWindow = onShowMainWindow
        self.onShowNotifications = onShowNotifications
        self.onOpenNotification = onOpenNotification
        self.onJumpToLatestUnread = onJumpToLatestUnread
        self.onOpenTaskManager = onOpenTaskManager
        self.onToggleSleepyMode = onToggleSleepyMode
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
            button.image = MenuBarIconRenderer.makeImage(unreadCount: 0)
            button.toolTip = "cmux"
        }

        notificationMenuSnapshotCancellable = notificationStore.$notificationMenuSnapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.refreshUI(snapshot: snapshot)
            }
        globalFontObserver = NotificationCenter.default.addObserver(
            forName: GlobalFontMagnification.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshUI() }
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

        sleepyModeItem.target = self
        sleepyModeItem.action = #selector(sleepyModeAction)
        menu.addItem(sleepyModeItem)

        caffeineItem.target = self
        caffeineItem.action = #selector(caffeineAction)
        menu.addItem(caffeineItem)

        menu.addItem(MenuBarProfilingMenuItem.make())
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
        if let globalFontObserver {
            NotificationCenter.default.removeObserver(globalFontObserver)
            self.globalFontObserver = nil
        }
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
        sleepyModeItem.state = SleepyModeController.shared.isActive ? .on : .off
        caffeineItem.state = caffeineController.isEnabled ? .on : .off

        applyShortcut(KeyboardShortcutSettings.menuShortcut(for: .globalSearch), to: globalSearchItem)
        applyShortcut(KeyboardShortcutSettings.menuShortcut(for: .showNotifications), to: showNotificationsItem)
        applyShortcut(KeyboardShortcutSettings.menuShortcut(for: .jumpToUnread), to: jumpToUnreadItem)
        applyShortcut(KeyboardShortcutSettings.menuShortcut(for: .markAllNotificationsRead), to: markAllReadItem)
        applyShortcut(KeyboardShortcutSettings.menuShortcut(for: .clearAllNotifications), to: clearAllItem)

        jumpToUnreadItem.isEnabled = snapshot.hasUnreadNotifications
        markAllReadItem.isEnabled = snapshot.hasUnreadNotifications
        clearAllItem.isEnabled = snapshot.hasNotifications

        rebuildInlineNotificationItems(recentNotifications: snapshot.recentNotifications)

        if let button = statusItem.button {
            button.image = MenuBarIconRenderer.makeImage(unreadCount: displayedUnreadCount)
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

        // Group into Today / Yesterday / Earlier, inserting a section header
        // before each group so the menu-bar list reads the same as the popover
        // and in-app page. Headers are tracked in `notificationItems` so they
        // are cleared and rebuilt together with the cards.
        var offset = 0
        for group in NotificationPresentation.grouped(recentNotifications) {
            let header = makeSectionHeaderItem(title: group.title)
            menu.insertItem(header, at: insertionIndex + offset)
            notificationItems.append(header)
            offset += 1
            for notification in group.notifications {
                let tabTitle = AppDelegate.shared?.tabTitle(for: notification.tabId)
                let item = makeNotificationItem(notification: notification, tabTitle: tabTitle)
                menu.insertItem(item, at: insertionIndex + offset)
                notificationItems.append(item)
                offset += 1
            }
        }
    }

    private func makeSectionHeaderItem(title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) {
            return NSMenuItem.sectionHeader(title: title)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func makeNotificationItem(notification: TerminalNotification, tabTitle: String?) -> NSMenuItem {
        // Use a custom view so the notification can carry its own tinted "card"
        // background — a native menu item can only style its text. The view
        // owns the click (a custom item view doesn't route through the item's
        // target/action), so it fires `onOpenNotification` on mouseDown.
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let onOpen = onOpenNotification
        item.view = NotificationMenuItemView(notification: notification, tabTitle: tabTitle) {
            onOpen(notification)
        }
        item.toolTip = MenuBarNotificationLineFormatter.tooltip(notification: notification, tabTitle: tabTitle)
        item.representedObject = NotificationMenuItemPayload(notification: notification)
        return item
    }

    @discardableResult
    func toggleGlobalSearchPalette(onDismiss: (() -> Void)? = nil) -> Bool {
        guard let button = statusItem.button else { return false }
        onShowGlobalSearch(button, onDismiss)
        return true
    }

    @objc private func globalSearchAction() {
        AppDelegate.shared?.toggleGlobalSearchPalette()
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

    @objc private func sleepyModeAction() {
        onToggleSleepyMode()
    }

    @objc private func caffeineAction() {
        caffeineController.toggle()
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

enum MenuBarBadgeLabelFormatter {
    static func badgeText(for unreadCount: Int) -> String? {
        guard unreadCount > 0 else { return nil }
        if unreadCount > 9 {
            return "9+"
        }
        return String(unreadCount)
    }
}

enum MenuBarNotificationLineFormatter {
    static let defaultMaxMenuTextWidth: CGFloat = 280
    static let defaultMaxMenuTextLines = 3

    static func plainTitle(notification: TerminalNotification, tabTitle: String?) -> String {
        let dot = notification.isRead ? "  " : "● "
        let timeText = notification.createdAt.formatted(date: .omitted, time: .shortened)
        var lines: [String] = []
        lines.append("\(dot)\(notification.title)  \(timeText)")

        let detail = notification.body.isEmpty ? notification.subtitle : notification.body
        if !detail.isEmpty {
            lines.append(detail)
        }

        if let tabTitle, !tabTitle.isEmpty {
            lines.append(tabTitle)
        }

        return lines.joined(separator: "\n")
    }

    static func menuTitle(
        notification: TerminalNotification,
        tabTitle: String?,
        maxWidth: CGFloat = defaultMaxMenuTextWidth,
        maxLines: Int = defaultMaxMenuTextLines
    ) -> String {
        let base = plainTitle(notification: notification, tabTitle: tabTitle)
        return wrappedAndTruncated(base, maxWidth: maxWidth, maxLines: maxLines)
    }

    static func attributedTitle(notification: TerminalNotification, tabTitle: String?) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(
            string: menuTitle(notification: notification, tabTitle: tabTitle),
            attributes: [
                .font: GlobalFontMagnification.menuFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
    }

    static func tooltip(notification: TerminalNotification, tabTitle: String?) -> String {
        plainTitle(notification: notification, tabTitle: tabTitle)
    }

    private static func wrappedAndTruncated(_ text: String, maxWidth: CGFloat, maxLines: Int) -> String {
        let width = max(60, maxWidth)
        let lines = max(1, maxLines)
        let font = GlobalFontMagnification.menuFont(ofSize: NSFont.systemFontSize)
        let wrapped = wrappedLines(for: text, maxWidth: width, font: font)
        guard wrapped.count > lines else { return wrapped.joined(separator: "\n") }

        var clipped = Array(wrapped.prefix(lines))
        clipped[lines - 1] = truncateLine(clipped[lines - 1], maxWidth: width, font: font)
        return clipped.joined(separator: "\n")
    }

    private static func wrappedLines(for text: String, maxWidth: CGFloat, font: NSFont) -> [String] {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: maxWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        _ = layout.glyphRange(for: container)

        let fullText = text as NSString
        var rows: [String] = []
        var glyphIndex = 0
        while glyphIndex < layout.numberOfGlyphs {
            var glyphRange = NSRange()
            layout.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &glyphRange)
            if glyphRange.length == 0 { break }

            let charRange = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let row = fullText.substring(with: charRange).trimmingCharacters(in: .newlines)
            rows.append(row)
            glyphIndex = NSMaxRange(glyphRange)
        }

        if rows.isEmpty {
            return [text]
        }
        return rows
    }

    private static func truncateLine(_ line: String, maxWidth: CGFloat, font: NSFont) -> String {
        let ellipsis = "…"
        let full = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if full.isEmpty { return ellipsis }

        if measuredWidth(full + ellipsis, font: font) <= maxWidth {
            return full + ellipsis
        }

        var chars = Array(full)
        while !chars.isEmpty {
            chars.removeLast()
            let candidateBase = String(chars).trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = (candidateBase.isEmpty ? "" : candidateBase) + ellipsis
            if measuredWidth(candidate, font: font) <= maxWidth {
                return candidate
            }
        }
        return ellipsis
    }

    private static func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
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

struct MenuBarBadgeRenderConfig {
    var badgeRect: NSRect
    var singleDigitFontSize: CGFloat
    var multiDigitFontSize: CGFloat
    var singleDigitYOffset: CGFloat
    var multiDigitYOffset: CGFloat
    var singleDigitXAdjust: CGFloat
    var multiDigitXAdjust: CGFloat
    var textRectWidthAdjust: CGFloat
}

enum MenuBarIconDebugSettings {
    static let previewEnabledKey = "menubarDebugPreviewEnabled"
    static let previewCountKey = "menubarDebugPreviewCount"
    static let badgeRectXKey = "menubarDebugBadgeRectX"
    static let badgeRectYKey = "menubarDebugBadgeRectY"
    static let badgeRectWidthKey = "menubarDebugBadgeRectWidth"
    static let badgeRectHeightKey = "menubarDebugBadgeRectHeight"
    static let singleDigitFontSizeKey = "menubarDebugSingleDigitFontSize"
    static let multiDigitFontSizeKey = "menubarDebugMultiDigitFontSize"
    static let singleDigitYOffsetKey = "menubarDebugSingleDigitYOffset"
    static let multiDigitYOffsetKey = "menubarDebugMultiDigitYOffset"
    static let singleDigitXAdjustKey = "menubarDebugSingleDigitXAdjust"
    static let legacySingleDigitXAdjustKey = "menubarDebugTextRectXAdjust"
    static let multiDigitXAdjustKey = "menubarDebugMultiDigitXAdjust"
    static let textRectWidthAdjustKey = "menubarDebugTextRectWidthAdjust"

    static let defaultBadgeRect = NSRect(x: 5.38, y: 6.43, width: 10.75, height: 11.58)
    static let defaultSingleDigitFontSize: CGFloat = 6.7
    static let defaultMultiDigitFontSize: CGFloat = 6.7
    static let defaultSingleDigitYOffset: CGFloat = 0.6
    static let defaultMultiDigitYOffset: CGFloat = 0.6
    static let defaultSingleDigitXAdjust: CGFloat = -1.1
    static let defaultMultiDigitXAdjust: CGFloat = 2.42
    static let defaultTextRectWidthAdjust: CGFloat = 1.8

    static func displayedUnreadCount(actualUnreadCount: Int, defaults: UserDefaults = .standard) -> Int {
        guard defaults.bool(forKey: previewEnabledKey) else { return actualUnreadCount }
        let value = defaults.integer(forKey: previewCountKey)
        return max(0, min(value, 99))
    }

    static func badgeRenderConfig(defaults: UserDefaults = .standard) -> MenuBarBadgeRenderConfig {
        let x = value(defaults, key: badgeRectXKey, fallback: defaultBadgeRect.origin.x, range: 0...20)
        let y = value(defaults, key: badgeRectYKey, fallback: defaultBadgeRect.origin.y, range: 0...20)
        let width = value(defaults, key: badgeRectWidthKey, fallback: defaultBadgeRect.width, range: 4...14)
        let height = value(defaults, key: badgeRectHeightKey, fallback: defaultBadgeRect.height, range: 4...14)
        let singleFont = value(defaults, key: singleDigitFontSizeKey, fallback: defaultSingleDigitFontSize, range: 6...14)
        let multiFont = value(defaults, key: multiDigitFontSizeKey, fallback: defaultMultiDigitFontSize, range: 6...14)
        let singleY = value(defaults, key: singleDigitYOffsetKey, fallback: defaultSingleDigitYOffset, range: -3...4)
        let multiY = value(defaults, key: multiDigitYOffsetKey, fallback: defaultMultiDigitYOffset, range: -3...4)
        let singleX = value(
            defaults,
            key: singleDigitXAdjustKey,
            legacyKey: legacySingleDigitXAdjustKey,
            fallback: defaultSingleDigitXAdjust,
            range: -4...4
        )
        let multiX = value(defaults, key: multiDigitXAdjustKey, fallback: defaultMultiDigitXAdjust, range: -4...4)
        let widthAdjust = value(defaults, key: textRectWidthAdjustKey, fallback: defaultTextRectWidthAdjust, range: -3...5)

        return MenuBarBadgeRenderConfig(
            badgeRect: NSRect(x: x, y: y, width: width, height: height),
            singleDigitFontSize: singleFont,
            multiDigitFontSize: multiFont,
            singleDigitYOffset: singleY,
            multiDigitYOffset: multiY,
            singleDigitXAdjust: singleX,
            multiDigitXAdjust: multiX,
            textRectWidthAdjust: widthAdjust
        )
    }

    static func copyPayload(defaults: UserDefaults = .standard) -> String {
        let config = badgeRenderConfig(defaults: defaults)
        let previewEnabled = defaults.bool(forKey: previewEnabledKey)
        let previewCount = max(0, min(defaults.integer(forKey: previewCountKey), 99))
        return """
        menubarDebugPreviewEnabled=\(previewEnabled)
        menubarDebugPreviewCount=\(previewCount)
        menubarDebugBadgeRectX=\(String(format: "%.2f", config.badgeRect.origin.x))
        menubarDebugBadgeRectY=\(String(format: "%.2f", config.badgeRect.origin.y))
        menubarDebugBadgeRectWidth=\(String(format: "%.2f", config.badgeRect.width))
        menubarDebugBadgeRectHeight=\(String(format: "%.2f", config.badgeRect.height))
        menubarDebugSingleDigitFontSize=\(String(format: "%.2f", config.singleDigitFontSize))
        menubarDebugMultiDigitFontSize=\(String(format: "%.2f", config.multiDigitFontSize))
        menubarDebugSingleDigitYOffset=\(String(format: "%.2f", config.singleDigitYOffset))
        menubarDebugMultiDigitYOffset=\(String(format: "%.2f", config.multiDigitYOffset))
        menubarDebugSingleDigitXAdjust=\(String(format: "%.2f", config.singleDigitXAdjust))
        menubarDebugMultiDigitXAdjust=\(String(format: "%.2f", config.multiDigitXAdjust))
        menubarDebugTextRectWidthAdjust=\(String(format: "%.2f", config.textRectWidthAdjust))
        """
    }

    private static func value(
        _ defaults: UserDefaults,
        key: String,
        legacyKey: String? = nil,
        fallback: CGFloat,
        range: ClosedRange<CGFloat>
    ) -> CGFloat {
        if let parsed = parse(defaults.object(forKey: key), fallback: fallback, range: range) {
            return parsed
        }
        if let legacyKey, let parsed = parse(defaults.object(forKey: legacyKey), fallback: fallback, range: range) {
            return parsed
        }
        return fallback
    }

    private static func parse(
        _ object: Any?,
        fallback: CGFloat,
        range: ClosedRange<CGFloat>
    ) -> CGFloat? {
        guard let number = object as? NSNumber else {
            return nil
        }
        let candidate = CGFloat(number.doubleValue)
        guard candidate.isFinite else { return fallback }
        return max(range.lowerBound, min(candidate, range.upperBound))
    }
}

enum MenuBarIconRenderer {

    static func makeImage(unreadCount: Int) -> NSImage {
        let badgeText = MenuBarBadgeLabelFormatter.badgeText(for: unreadCount)
        let config = MenuBarIconDebugSettings.badgeRenderConfig()
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let glyphRect = NSRect(x: 1.2, y: 1.5, width: 11.6, height: 15.0)
        drawGlyph(in: glyphRect)

        if let text = badgeText {
            drawBadge(text: text, in: config.badgeRect, config: config)
        }

        image.isTemplate = true
        return image
    }

    private static func drawGlyph(in rect: NSRect) {
        // Match the canonical cmux center-mark path from Icon Center Image Artwork.svg.
        let srcMinX: CGFloat = 384.0
        let srcMinY: CGFloat = 255.0
        let srcWidth: CGFloat = 369.0
        let srcHeight: CGFloat = 513.0

        func map(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            let nx = (x - srcMinX) / srcWidth
            let ny = (y - srcMinY) / srcHeight
            return NSPoint(
                x: rect.minX + nx * rect.width,
                y: rect.minY + (1.0 - ny) * rect.height
            )
        }

        let path = NSBezierPath()
        path.move(to: map(384.0, 255.0))
        path.line(to: map(753.0, 511.5))
        path.line(to: map(384.0, 768.0))
        path.line(to: map(384.0, 654.0))
        path.line(to: map(582.692, 511.5))
        path.line(to: map(384.0, 369.0))
        path.close()

        NSColor.black.setFill()
        path.fill()
    }

    private static func drawBadge(text: String, in rect: NSRect, config: MenuBarBadgeRenderConfig) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let fontSize: CGFloat = text.count > 1 ? config.multiDigitFontSize : config.singleDigitFontSize
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold), // Fixed 18x18 status-item bitmap.
            .foregroundColor: NSColor.systemBlue,
            .paragraphStyle: paragraph,
        ]
        let yOffset: CGFloat = text.count > 1 ? config.multiDigitYOffset : config.singleDigitYOffset
        let xAdjust: CGFloat = text.count > 1 ? config.multiDigitXAdjust : config.singleDigitXAdjust
        let textRect = NSRect(
            x: rect.origin.x + xAdjust,
            y: rect.origin.y + yOffset,
            width: rect.width + config.textRectWidthAdjust,
            height: rect.height
        )
        (text as NSString).draw(in: textRect, withAttributes: attrs)
    }
}

/// A premium-looking custom view for a notification row inside the menu-bar
/// dropdown. A native `NSMenuItem` can only style its text, so it can't carry
/// its own background; giving the item a custom `view` lets us draw a subtle
/// tinted "card" behind each notification, an icon chip, and a relative
/// timestamp so notifications stand out from the plain command items around
/// them. Modeled on `MouseDownMenuItemView`: full-width so the highlight spans
/// the menu, hover tracking, and `mouseDown` cancels menu tracking then fires
/// the open action (a custom item view does not route through the item's
/// target/action automatically).
@MainActor
final class NotificationMenuItemView: NSView {
    private static let defaultWidth: CGFloat = 320
    private static let cardInsetH: CGFloat = 6
    private static let cardInsetV: CGFloat = 2
    private static let cardCornerRadius: CGFloat = 8
    private static let contentPadH: CGFloat = 10
    private static let contentPadV: CGFloat = 8
    private static let chipSize: CGFloat = 26
    private static let chipCornerRadius: CGFloat = 6
    private static let chipToTextSpacing: CGFloat = 10

    private let notification: TerminalNotification
    private let action: () -> Void

    private let chipContainer = NSView()
    private let chipImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let workspaceLabel = NSTextField(labelWithString: "")
    private let unreadDot = NSView()

    private var trackingArea: NSTrackingArea?
    private var isHighlighted = false {
        didSet {
            guard oldValue != isHighlighted else { return }
            needsDisplay = true
            applyColors()
        }
    }

    init(notification: TerminalNotification, tabTitle: String?, action: @escaping () -> Void) {
        self.notification = notification
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: Self.defaultWidth, height: 44))
        // Let the highlight/card span the full menu width like a native item.
        autoresizingMask = [.width]
        wantsLayer = true

        let baseSize = GlobalFontMagnification.menuFont(ofSize: NSFont.systemFontSize).pointSize

        chipContainer.wantsLayer = true
        chipContainer.layer?.cornerRadius = Self.chipCornerRadius
        chipContainer.translatesAutoresizingMaskIntoConstraints = false
        chipImageView.translatesAutoresizingMaskIntoConstraints = false
        chipImageView.imageScaling = .scaleProportionallyUpOrDown
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: baseSize - 1, weight: .semibold)
        chipImageView.image = NSImage(
            systemSymbolName: NotificationPresentation.symbolName(for: notification),
            accessibilityDescription: nil
        )?.withSymbolConfiguration(symbolConfig)
        chipContainer.addSubview(chipImageView)

        configureLabel(titleLabel, font: .systemFont(ofSize: baseSize, weight: .semibold), maxLines: 1)
        configureLabel(timeLabel, font: .systemFont(ofSize: baseSize - 2), maxLines: 1)
        configureLabel(bodyLabel, font: .systemFont(ofSize: baseSize - 1), maxLines: 2)
        configureLabel(workspaceLabel, font: .systemFont(ofSize: baseSize - 2), maxLines: 1)

        titleLabel.stringValue = notification.title
        timeLabel.stringValue = NotificationPresentation.relativeTimeString(for: notification.createdAt)
        let detail = notification.body.isEmpty ? notification.subtitle : notification.body
        bodyLabel.stringValue = detail
        bodyLabel.isHidden = detail.isEmpty
        workspaceLabel.stringValue = tabTitle ?? ""
        workspaceLabel.isHidden = (tabTitle ?? "").isEmpty

        // Title takes remaining width and truncates; time hugs the trailing edge.
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        unreadDot.wantsLayer = true
        unreadDot.layer?.cornerRadius = 3.5
        unreadDot.translatesAutoresizingMaskIntoConstraints = false
        unreadDot.isHidden = notification.isRead

        let titleRow = NSStackView(views: [titleLabel, unreadDot, timeLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6
        titleRow.distribution = .fill
        titleRow.setHuggingPriority(.defaultLow, for: .horizontal)

        let textColumn = NSStackView(views: [titleRow, bodyLabel, workspaceLabel])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 2
        textColumn.translatesAutoresizingMaskIntoConstraints = false
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        addSubview(chipContainer)
        addSubview(textColumn)

        let leading = Self.cardInsetH + Self.contentPadH
        let trailing = Self.cardInsetH + Self.contentPadH + 2
        let top = Self.cardInsetV + Self.contentPadV
        NSLayoutConstraint.activate([
            chipContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            chipContainer.topAnchor.constraint(equalTo: topAnchor, constant: top),
            chipContainer.widthAnchor.constraint(equalToConstant: Self.chipSize),
            chipContainer.heightAnchor.constraint(equalToConstant: Self.chipSize),
            chipImageView.centerXAnchor.constraint(equalTo: chipContainer.centerXAnchor),
            chipImageView.centerYAnchor.constraint(equalTo: chipContainer.centerYAnchor),

            unreadDot.widthAnchor.constraint(equalToConstant: 7),
            unreadDot.heightAnchor.constraint(equalToConstant: 7),

            textColumn.leadingAnchor.constraint(equalTo: chipContainer.trailingAnchor, constant: Self.chipToTextSpacing),
            textColumn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailing),
            textColumn.topAnchor.constraint(equalTo: topAnchor, constant: top),
            // A vertical NSStackView with .leading alignment does not stretch its
            // rows to the column width, so pin each row's width to the column.
            // This right-aligns the time in the title row and gives the body a
            // definite width to wrap within.
            titleRow.widthAnchor.constraint(equalTo: textColumn.widthAnchor),
            bodyLabel.widthAnchor.constraint(equalTo: textColumn.widthAnchor),
            workspaceLabel.widthAnchor.constraint(equalTo: textColumn.widthAnchor),
            // The view's bottom is the lower of the chip and the text column,
            // plus the bottom inset — so short (title-only) and tall (title +
            // 2-line body + workspace) notifications both size correctly.
            bottomAnchor.constraint(greaterThanOrEqualTo: textColumn.bottomAnchor, constant: top),
            bottomAnchor.constraint(greaterThanOrEqualTo: chipContainer.bottomAnchor, constant: top),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        let axParts = [notification.title, detail, tabTitle ?? ""].filter { !$0.isEmpty }
        setAccessibilityLabel(axParts.joined(separator: ", "))

        applyColors()

        // Resolve the content height once so the menu allocates the right row
        // height. Width is fixed to the default here; the menu sizes to its
        // widest item, so this card (usually the widest) defines that width and
        // the measured height holds. A wider menu only reduces body wrapping.
        layoutSubtreeIfNeeded()
        frame = NSRect(x: 0, y: 0, width: Self.defaultWidth, height: fittingSize.height)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureLabel(_ label: NSTextField, font: NSFont, maxLines: Int) {
        label.font = font
        label.maximumNumberOfLines = maxLines
        label.lineBreakMode = maxLines == 1 ? .byTruncatingTail : .byWordWrapping
        if maxLines > 1 {
            label.cell?.truncatesLastVisibleLine = true
        }
        label.translatesAutoresizingMaskIntoConstraints = false
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { isHighlighted = true }
    override func mouseExited(with event: NSEvent) { isHighlighted = false }

    override func mouseDown(with event: NSEvent) {
        isHighlighted = true
        enclosingMenuItem?.menu?.cancelTrackingWithoutAnimation()
        action()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        needsDisplay = true
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private var cardFill: NSColor {
        if notification.isRead {
            return (isDark ? NSColor.white : NSColor.black).withAlphaComponent(isDark ? 0.06 : 0.045)
        }
        return NSColor.controlAccentColor.withAlphaComponent(isDark ? 0.22 : 0.12)
    }

    private func applyColors() {
        let selectedText = NSColor.selectedMenuItemTextColor
        if isHighlighted {
            titleLabel.textColor = selectedText
            timeLabel.textColor = selectedText.withAlphaComponent(0.85)
            bodyLabel.textColor = selectedText.withAlphaComponent(0.9)
            workspaceLabel.textColor = selectedText.withAlphaComponent(0.75)
            chipContainer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
            chipImageView.contentTintColor = .white
            unreadDot.layer?.backgroundColor = NSColor.white.cgColor
        } else {
            titleLabel.textColor = .labelColor
            timeLabel.textColor = .tertiaryLabelColor
            bodyLabel.textColor = .secondaryLabelColor
            workspaceLabel.textColor = .tertiaryLabelColor
            let chipFill: NSColor = notification.isRead
                ? (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.10)
                : NSColor.controlAccentColor.withAlphaComponent(isDark ? 0.35 : 0.18)
            chipContainer.layer?.backgroundColor = chipFill.cgColor
            chipImageView.contentTintColor = notification.isRead ? .secondaryLabelColor : .controlAccentColor
            unreadDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let cardRect = bounds.insetBy(dx: Self.cardInsetH, dy: Self.cardInsetV)
        let path = NSBezierPath(
            roundedRect: cardRect,
            xRadius: Self.cardCornerRadius,
            yRadius: Self.cardCornerRadius
        )
        (isHighlighted ? NSColor.selectedContentBackgroundColor : cardFill).setFill()
        path.fill()
    }
}
