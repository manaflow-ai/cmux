import AppKit
import Combine
import Foundation

@MainActor
final class MenuBarExtraController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu(title: "cmux")
    private let notificationStore: TerminalNotificationStore
    private let onShowNotifications: () -> Void
    private let onOpenNotification: (TerminalNotification) -> Void
    private let onJumpToLatestUnread: () -> Void
    private let onCheckForUpdates: () -> Void
    private let onOpenPreferences: () -> Void
    private let onQuitApp: () -> Void
    private var notificationsCancellable: AnyCancellable?
    private let buildHintTitle: String?

    private let stateHintItem = NSMenuItem(title: String(localized: "statusMenu.noUnread", defaultValue: "No unread notifications"), action: nil, keyEquivalent: "")
    private let buildHintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
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
    private let maxInlineNotificationItems = 6

    init(
        notificationStore: TerminalNotificationStore,
        onShowNotifications: @escaping () -> Void,
        onOpenNotification: @escaping (TerminalNotification) -> Void,
        onJumpToLatestUnread: @escaping () -> Void,
        onCheckForUpdates: @escaping () -> Void,
        onOpenPreferences: @escaping () -> Void,
        onQuitApp: @escaping () -> Void
    ) {
        self.notificationStore = notificationStore
        self.onShowNotifications = onShowNotifications
        self.onOpenNotification = onOpenNotification
        self.onJumpToLatestUnread = onJumpToLatestUnread
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

        notificationsCancellable = notificationStore.$notifications
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshUI()
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
        notificationsCancellable?.cancel()
        notificationsCancellable = nil
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func refreshUI() {
        let snapshot = NotificationMenuSnapshotBuilder.make(
            notifications: notificationStore.notifications,
            maxInlineNotificationItems: maxInlineNotificationItems
        )
        let actualUnreadCount = snapshot.unreadCount

        let displayedUnreadCount: Int
#if DEBUG
        displayedUnreadCount = MenuBarIconDebugSettings.displayedUnreadCount(actualUnreadCount: actualUnreadCount)
#else
        displayedUnreadCount = actualUnreadCount
#endif

        stateHintItem.title = snapshot.stateHintTitle

        applyShortcut(KeyboardShortcutSettings.shortcut(for: .showNotifications), to: showNotificationsItem)
        applyShortcut(KeyboardShortcutSettings.shortcut(for: .jumpToUnread), to: jumpToUnreadItem)

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
        item.attributedTitle = MenuBarNotificationLineFormatter.attributedTitle(notification: notification, tabTitle: tabTitle)
        item.toolTip = MenuBarNotificationLineFormatter.tooltip(notification: notification, tabTitle: tabTitle)
        item.representedObject = NotificationMenuItemPayload(notification: notification)
        return item
    }

    @objc private func openNotificationItemAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? NotificationMenuItemPayload else { return }
        onOpenNotification(payload.notification)
    }

    @objc private func showNotificationsAction() {
        onShowNotifications()
    }

    @objc private func jumpToUnreadAction() {
        onJumpToLatestUnread()
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

struct NotificationMenuSnapshot {
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
        maxInlineNotificationItems: Int = defaultInlineNotificationLimit
    ) -> NotificationMenuSnapshot {
        let unreadCount = notifications.reduce(into: 0) { count, notification in
            if !notification.isRead {
                count += 1
            }
        }

        let inlineLimit = max(0, maxInlineNotificationItems)
        return NotificationMenuSnapshot(
            unreadCount: unreadCount,
            hasNotifications: !notifications.isEmpty,
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
                .font: NSFont.menuFont(ofSize: NSFont.systemFontSize),
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
        let font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
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
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
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


