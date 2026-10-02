import Foundation

/// Localized strings of sidebar sections (Resources/Localizable.xcstrings).
enum SectionStrings {
    static var home: String { String(localized: "sidebar.builtin.home", defaultValue: "Home", bundle: .module) }
    static var settings: String { String(localized: "sidebar.builtin.settings", defaultValue: "Settings", bundle: .module) }
    static var account: String { String(localized: "sidebar.builtin.account", defaultValue: "Account", bundle: .module) }
    static var notifications: String { String(localized: "sidebar.builtin.notifications", defaultValue: "Notifications", bundle: .module) }
    static var history: String { String(localized: "sidebar.builtin.history", defaultValue: "History", bundle: .module) }
    static var bookmarks: String { String(localized: "sidebar.builtin.bookmarks", defaultValue: "Bookmarks", bundle: .module) }
    static var appStore: String { String(localized: "sidebar.builtin.appStore", defaultValue: "App Store", bundle: .module) }
    static var newTerminal: String { String(localized: "sidebar.builtin.newTerminal", defaultValue: "New Terminal Tab", bundle: .module) }
    static var newBrowser: String { String(localized: "sidebar.builtin.newBrowser", defaultValue: "New Browser Tab", bundle: .module) }
    static var newAgentChat: String { String(localized: "sidebar.builtin.newAgentChat", defaultValue: "New Agent Chat", bundle: .module) }
    /// The rail's button for items that do not fit.
    static var more: String { String(localized: "sidebar.rail.more", defaultValue: "More…", bundle: .module) }
    static var customize: String { String(localized: "sidebar.builtin.customize", defaultValue: "Customize Appearance", bundle: .module) }
    static var collapse: String { String(localized: "sidebar.sections.collapse", defaultValue: "Collapse", bundle: .module) }
    static var expand: String { String(localized: "sidebar.sections.expand", defaultValue: "Expand", bundle: .module) }
}
