import Foundation

/// Strings of the sidebar section handlers (SidebarSections.xcstrings).
enum SidebarSectionStrings {
    static func rejected(_ reason: String) -> String {
        String(format: String(localized: "sidebarSections.rejected", defaultValue: "the sidebar layout refused this change (%@)",
                              table: "SidebarSections", bundle: .module), reason)
    }
    static var noSuchSection: String {
        String(localized: "sidebarSections.noSuchSection", defaultValue: "no such sidebar section", table: "SidebarSections", bundle: .module)
    }
    static var noSuchItem: String {
        String(localized: "sidebarSections.noSuchItem", defaultValue: "no such sidebar item", table: "SidebarSections", bundle: .module)
    }
    static var homeAlreadyShown: String {
        String(localized: "sidebarSections.homeAlreadyShown", defaultValue: "Home is already in the sidebar", table: "SidebarSections", bundle: .module)
    }
    static var homeNotShown: String {
        String(localized: "sidebarSections.homeNotShown", defaultValue: "Home is not in the sidebar", table: "SidebarSections", bundle: .module)
    }
    static var untitledSection: String {
        String(localized: "sidebarSections.untitled", defaultValue: "Untitled section", table: "SidebarSections", bundle: .module)
    }
    static var workspacesSection: String {
        String(localized: "sidebarSections.workspaces", defaultValue: "Workspaces", table: "SidebarSections", bundle: .module)
    }
}
