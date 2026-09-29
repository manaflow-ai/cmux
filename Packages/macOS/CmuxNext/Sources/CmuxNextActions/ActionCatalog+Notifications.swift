// Catalog rows for one inventory domain. Titles live in Localizable.xcstrings (en, ja).

extension ActionCatalog {
    static func notificationsActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "showNotifications",
                title: String(localized: "action.showNotifications", defaultValue: "Show Notifications", bundle: .module),
                keywords: ["inbox", "alerts"], defaultShortcut: Shortcut("i", modifiers: [.command]),
                category: .notifications, symbol: "bell", surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "jumpToUnread",
                title: String(localized: "action.jumpToUnread", defaultValue: "Jump to Latest Unread", bundle: .module),
                keywords: ["notifications", "next"], defaultShortcut: Shortcut("u", modifiers: [.command, .shift]),
                category: .notifications, symbol: "bell.badge", surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "toggleUnread",
                title: String(localized: "action.toggleUnread", defaultValue: "Toggle Unread", bundle: .module),
                keywords: ["notifications", "read"], defaultShortcut: Shortcut("u", modifiers: [.option, .command]),
                category: .notifications, symbol: "circle.badge", surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "markOldestUnreadAndJumpNext",
                title: String(localized: "action.markOldestUnreadAndJumpNext", defaultValue: "Mark Oldest Unread and Jump Next", bundle: .module),
                keywords: ["notifications", "triage"], defaultShortcut: Shortcut("u", modifiers: [.control, .command]),
                category: .notifications, symbol: "bell.and.waves.left.and.right", surfaces: [.palette, .keyboard]
            ),
            ActionDescriptor(
                id: "markAllNotificationsRead",
                title: String(localized: "action.markAllNotificationsRead", defaultValue: "Mark All Notifications as Read", bundle: .module),
                keywords: ["notifications", "read"], category: .notifications, symbol: "checkmark.circle",
                surfaces: [.keyboard, .menu]
            ),
            ActionDescriptor(
                id: "clearAllNotifications",
                title: String(localized: "action.clearAllNotifications", defaultValue: "Clear All Notifications", bundle: .module),
                keywords: ["notifications", "dismiss"], category: .notifications, symbol: "bell.slash",
                surfaces: [.keyboard, .menu]
            ),
            ActionDescriptor(
                id: "notificationOpen",
                title: String(localized: "action.notificationOpen", defaultValue: "Open Notification", bundle: .module),
                keywords: ["notifications"], category: .notifications, symbol: "bell.circle", surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "notificationCopy",
                title: String(localized: "action.notificationCopy", defaultValue: "Copy Notification", bundle: .module),
                keywords: ["notifications", "clipboard"], category: .notifications, symbol: "doc.on.doc",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "notificationToggleRead",
                title: String(localized: "action.notificationToggleRead", defaultValue: "Mark Notification Read/Unread", bundle: .module),
                keywords: ["notifications"], category: .notifications, symbol: "envelope", surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "notificationDismiss",
                title: String(localized: "action.notificationDismiss", defaultValue: "Dismiss Notification", bundle: .module),
                keywords: ["notifications"], category: .notifications, symbol: "xmark.circle", surfaces: [.contextMenu]
            ),
        ]
    }
}
