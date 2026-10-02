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
    static var collapse: String { String(localized: "sidebar.sections.collapse", defaultValue: "Collapse", bundle: .module) }
    static var expand: String { String(localized: "sidebar.sections.expand", defaultValue: "Expand", bundle: .module) }
}
