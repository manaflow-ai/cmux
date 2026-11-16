import Foundation

/// The custom sidebar toggle's menu titles, toast and refusals (CustomSidebar.xcstrings).
nonisolated enum CustomSidebarStrings {
    static var show: String { text("customSidebar.menu.show", "Show Custom Sidebar") }
    static var hide: String { text("customSidebar.menu.hide", "Hide Custom Sidebar") }
    static var create: String { text("customSidebar.menu.create", "Create Custom Sidebar") }
    static var created: String { text("customSidebar.created", "Custom sidebar created. Edit main.js to change it.") }
    static var noHome: String { text("customSidebar.noHome", "No home folder is set, so there is no customize folder.") }
    static func unreadable(_ path: String) -> String {
        String(format: text("customSidebar.unreadable", "The custom sidebar did not load: fix %@, then save it."), path)
    }
    static func couldNotCreate(_ reason: String) -> String {
        String(format: text("customSidebar.couldNotCreate", "The custom sidebar was not created: %@"), reason)
    }

    private static func text(_ key: String, _ english: String) -> String {
        Bundle.module.localizedString(forKey: key, value: english, table: "CustomSidebar")
    }
}
