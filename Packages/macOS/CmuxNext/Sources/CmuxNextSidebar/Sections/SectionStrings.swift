import Foundation

/// Localized strings of sidebar sections (Resources/Localizable.xcstrings).
enum SectionStrings {
    static var home: String { String(localized: "sidebar.builtin.home", defaultValue: "Chief", bundle: .localizedModule) }
    /// The Channels entry after Home (`SidebarTransientItem.channels`).
    static var channels: String { String(localized: "sidebar.builtin.channels", defaultValue: "Channels", bundle: .localizedModule) }
    static var settings: String { String(localized: "sidebar.builtin.settings", defaultValue: "Settings", bundle: .localizedModule) }
    static var account: String { String(localized: "sidebar.builtin.account", defaultValue: "Account", bundle: .localizedModule) }
    static var notifications: String { String(localized: "sidebar.builtin.notifications", defaultValue: "Notifications", bundle: .localizedModule) }
    static var history: String { String(localized: "sidebar.builtin.history", defaultValue: "History", bundle: .localizedModule) }
    static var bookmarks: String { String(localized: "sidebar.builtin.bookmarks", defaultValue: "Bookmarks", bundle: .localizedModule) }
    static var automations: String { String(localized: "sidebar.builtin.automations", defaultValue: "Automations", bundle: .localizedModule) }
    static var machines: String { String(localized: "sidebar.builtin.machines", defaultValue: "Machines", bundle: .localizedModule) }
    static var appStore: String { String(localized: "sidebar.builtin.appStore", defaultValue: "App Store", bundle: .localizedModule) }
    static var newTerminal: String { String(localized: "sidebar.builtin.newTerminal", defaultValue: "New Terminal Tab", bundle: .localizedModule) }
    static var newBrowser: String { String(localized: "sidebar.builtin.newBrowser", defaultValue: "New Browser Tab", bundle: .localizedModule) }
    static var newAgentChat: String { String(localized: "sidebar.builtin.newAgentChat", defaultValue: "New Agent Chat", bundle: .localizedModule) }
    static var searchChats: String { String(localized: "sidebar.builtin.searchChats", defaultValue: "Search Chats", bundle: .localizedModule) }
    static var chief: String { String(localized: "sidebar.builtin.chief", defaultValue: "Chief Activity", bundle: .localizedModule) }
    /// Short tile captions (a tiles section's items, Safari's favorites).
    static var appStoreCaption: String { String(localized: "sidebar.builtin.appStore.caption", defaultValue: "Apps", bundle: .localizedModule) }
    /// The rail's button for items that do not fit.
    static var customize: String { String(localized: "sidebar.builtin.customize", defaultValue: "Customize Appearance", bundle: .localizedModule) }
    /// An icon's tooltip with its shortcut: "Settings (⌘,)".
    static func titleWithShortcut(_ title: String, _ shortcut: String) -> String {
        String(format: String(localized: "sidebar.item.titleWithShortcut", defaultValue: "%1$@ (%2$@)", bundle: .localizedModule), title, shortcut)
    }
    static var collapse: String { String(localized: "sidebar.sections.collapse", defaultValue: "Collapse", bundle: .localizedModule) }
    static var expand: String { String(localized: "sidebar.sections.expand", defaultValue: "Expand", bundle: .localizedModule) }
}
