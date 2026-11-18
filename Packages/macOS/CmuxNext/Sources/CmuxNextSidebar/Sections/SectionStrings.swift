import Foundation

/// Localized strings of sidebar sections (Resources/Localizable.xcstrings).
enum SectionStrings {
    static var home: String { String(localized: "sidebar.builtin.home", defaultValue: "Home", bundle: .l10n) }
    /// The Channels entry after Home (`SidebarTransientItem.channels`).
    static var channels: String { String(localized: "sidebar.builtin.channels", defaultValue: "Channels", bundle: .l10n) }
    static var settings: String { String(localized: "sidebar.builtin.settings", defaultValue: "Settings", bundle: .l10n) }
    static var account: String { String(localized: "sidebar.builtin.account", defaultValue: "Account", bundle: .l10n) }
    static var notifications: String { String(localized: "sidebar.builtin.notifications", defaultValue: "Notifications", bundle: .l10n) }
    static var history: String { String(localized: "sidebar.builtin.history", defaultValue: "History", bundle: .l10n) }
    static var bookmarks: String { String(localized: "sidebar.builtin.bookmarks", defaultValue: "Bookmarks", bundle: .l10n) }
    static var automations: String { String(localized: "sidebar.builtin.automations", defaultValue: "Automations", bundle: .l10n) }
    static var appStore: String { String(localized: "sidebar.builtin.appStore", defaultValue: "App Store", bundle: .l10n) }
    static var newTerminal: String { String(localized: "sidebar.builtin.newTerminal", defaultValue: "New Terminal Tab", bundle: .l10n) }
    static var newBrowser: String { String(localized: "sidebar.builtin.newBrowser", defaultValue: "New Browser Tab", bundle: .l10n) }
    static var newAgentChat: String { String(localized: "sidebar.builtin.newAgentChat", defaultValue: "New Agent Chat", bundle: .l10n) }
    static var searchChats: String { String(localized: "sidebar.builtin.searchChats", defaultValue: "Search Chats", bundle: .l10n) }
    static var chief: String { String(localized: "sidebar.builtin.chief", defaultValue: "Chief", bundle: .l10n) }
    /// Short tile captions (a tiles section's items, Safari's favorites).
    static var appStoreCaption: String { String(localized: "sidebar.builtin.appStore.caption", defaultValue: "Apps", bundle: .l10n) }
    /// The rail's button for items that do not fit.
    static var customize: String { String(localized: "sidebar.builtin.customize", defaultValue: "Customize Appearance", bundle: .l10n) }
    /// An icon's tooltip with its shortcut: "Settings (⌘,)".
    static func titleWithShortcut(_ title: String, _ shortcut: String) -> String {
        String(format: String(localized: "sidebar.item.titleWithShortcut", defaultValue: "%1$@ (%2$@)", bundle: .l10n), title, shortcut)
    }
    static var collapse: String { String(localized: "sidebar.sections.collapse", defaultValue: "Collapse", bundle: .l10n) }
    static var expand: String { String(localized: "sidebar.sections.expand", defaultValue: "Expand", bundle: .l10n) }
}
