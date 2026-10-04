// Catalog rows for one domain. Titles live in Localizable.xcstrings (en, ja).

nonisolated enum NotificationActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "feed.show",
                title: String(localized: "action.feed.show", defaultValue: "Show Feed", bundle: .module),
                keywords: ["inbox", "requests", "notifications", "approvals"], defaultShortcut: Shortcut("i", modifiers: [.command]),
                category: .notifications, symbol: "tray.full", surfaces: [.palette, .keyboard, .menu],
                cliName: "feed show", mainMenu: .window
            ),
            ActionDescriptor(
                id: "showNotifications",
                title: String(localized: "action.showNotifications", defaultValue: "Show Notifications", bundle: .module),
                keywords: ["inbox", "alerts"],
                category: .notifications, symbol: "bell", surfaces: [.palette, .keyboard, .menu],
                cliName: "notification show", mainMenu: .window
            ),
            ActionDescriptor(
                id: "jumpToUnread",
                title: String(localized: "action.jumpToUnread", defaultValue: "Jump to Latest Unread", bundle: .module),
                keywords: ["notifications", "next"], defaultShortcut: Shortcut("u", modifiers: [.command, .shift]),
                category: .notifications, symbol: "bell.badge", surfaces: [.palette, .keyboard, .menu],
                cliName: "notification jump-to-latest-unread", mainMenu: .window
            ),
            ActionDescriptor(
                id: "toggleUnread",
                title: String(localized: "action.toggleUnread", defaultValue: "Toggle Unread", bundle: .module),
                keywords: ["notifications", "read"], defaultShortcut: Shortcut("u", modifiers: [.option, .command]),
                category: .notifications, symbol: "circle.badge", surfaces: [.palette, .keyboard, .menu],
                cliName: "notification toggle-unread", mainMenu: .window
            ),
            ActionDescriptor(
                id: "markOldestUnreadAndJumpNext",
                title: String(localized: "action.markOldestUnreadAndJumpNext", defaultValue: "Mark Oldest Unread and Jump Next", bundle: .module),
                keywords: ["notifications", "triage"], defaultShortcut: Shortcut("u", modifiers: [.control, .command]),
                category: .notifications, symbol: "bell.and.waves.left.and.right", surfaces: [.palette, .keyboard],
                cliName: "notification mark-oldest-unread-and-jump-next"
            ),
            ActionDescriptor(
                id: "markAllNotificationsRead",
                title: String(localized: "action.markAllNotificationsRead", defaultValue: "Mark All Notifications as Read", bundle: .module),
                keywords: ["notifications", "read"], category: .notifications, symbol: "checkmark.circle",
                surfaces: [.keyboard, .menu], cliName: "notification mark-all-as-read", mainMenu: .window
            ),
            ActionDescriptor(
                id: "clearAllNotifications",
                title: String(localized: "action.clearAllNotifications", defaultValue: "Clear All Notifications", bundle: .module),
                keywords: ["notifications", "dismiss"], category: .notifications, symbol: "bell.slash",
                surfaces: [.keyboard, .menu], cliName: "notification clear-all", mainMenu: .window
            ),
            ActionDescriptor(
                id: "notificationOpen",
                title: String(localized: "action.notificationOpen", defaultValue: "Open Notification", bundle: .module),
                keywords: ["notifications"], category: .notifications, symbol: "bell.circle", surfaces: [.contextMenu],
                cliName: "notification open"
            ),
            ActionDescriptor(
                id: "notificationCopy",
                title: String(localized: "action.notificationCopy", defaultValue: "Copy Notification", bundle: .module),
                keywords: ["notifications", "clipboard"], category: .notifications, symbol: "doc.on.doc",
                surfaces: [.contextMenu], cliName: "notification copy"
            ),
            ActionDescriptor(
                id: "notificationToggleRead",
                title: String(localized: "action.notificationToggleRead", defaultValue: "Mark Notification Read/Unread", bundle: .module),
                keywords: ["notifications"], category: .notifications, symbol: "envelope", surfaces: [.contextMenu],
                cliName: "notification mark-read-unread"
            ),
            ActionDescriptor(
                id: "notificationDismiss",
                title: String(localized: "action.notificationDismiss", defaultValue: "Dismiss Notification", bundle: .module),
                keywords: ["notifications"], category: .notifications, symbol: "xmark.circle", surfaces: [.contextMenu],
                cliName: "notification dismiss"
            ),
            ActionDescriptor(
                id: "notifications.toggleWorkspaceMute",
                title: String(localized: "action.notifications.toggleWorkspaceMute", defaultValue: "Mute or Unmute Workspace Notifications", bundle: .module),
                keywords: ["mute", "silence", "quiet", "notifications", "workspace"], category: .notifications, symbol: "bell.slash.circle",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.workspace], cliName: "notification toggle-workspace-mute"
            ),
            ActionDescriptor(
                id: "notifications.toggleBanners",
                title: String(localized: "action.notifications.toggleBanners", defaultValue: "Toggle Notification Banners", bundle: .module),
                keywords: ["banner", "desktop", "system", "macos", "notifications"], category: .notifications, symbol: "rectangle.stack.badge.minus",
                surfaces: [.palette, .keyboard], cliName: "notification toggle-banners"
            ),
            ActionDescriptor(
                id: "notifications.dismissal.keystroke",
                title: String(localized: "action.notifications.dismissal.keystroke", defaultValue: "Clear Notifications When Typing", bundle: .module),
                keywords: ["dismiss", "clear", "keystroke", "typing", "notifications"], category: .notifications, symbol: "keyboard",
                surfaces: [.palette], cliName: "notification clear-when-typing"
            ),
            ActionDescriptor(
                id: "notifications.dismissal.focus",
                title: String(localized: "action.notifications.dismissal.focus", defaultValue: "Clear Notifications on Focus", bundle: .module),
                keywords: ["dismiss", "clear", "focus", "notifications"], category: .notifications, symbol: "scope",
                surfaces: [.palette], cliName: "notification clear-on-focus"
            ),
            ActionDescriptor(
                id: "notifications.dismissal.click",
                title: String(localized: "action.notifications.dismissal.click", defaultValue: "Clear Notifications on Click", bundle: .module),
                keywords: ["dismiss", "clear", "click", "notifications"], category: .notifications, symbol: "cursorarrow.click",
                surfaces: [.palette], cliName: "notification clear-on-click"
            ),
            ActionDescriptor(
                id: "notifications.dismissal.explicit",
                title: String(localized: "action.notifications.dismissal.explicit", defaultValue: "Clear Notifications Only When Opened", bundle: .module),
                keywords: ["dismiss", "clear", "open", "explicit", "notifications"], category: .notifications, symbol: "envelope.open",
                surfaces: [.palette], cliName: "notification clear-when-opened"
            ),
            ActionDescriptor(
                id: "notifications.dismissal.timeout",
                title: String(localized: "action.notifications.dismissal.timeout", defaultValue: "Clear Notifications After a Timeout", bundle: .module),
                keywords: ["dismiss", "clear", "timeout", "timer", "notifications"], category: .notifications, symbol: "timer",
                surfaces: [.palette], cliName: "notification clear-after-timeout"
            ),
            ActionDescriptor(
                id: "notifications.dismissal.never",
                title: String(localized: "action.notifications.dismissal.never", defaultValue: "Never Clear Notifications Automatically", bundle: .module),
                keywords: ["dismiss", "clear", "never", "manual", "notifications"], category: .notifications, symbol: "pin",
                surfaces: [.palette], cliName: "notification never-clear-automatically"
            ),
        ]
    }
}
