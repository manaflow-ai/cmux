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
    static var alreadyOnTop: String {
        String(localized: "sidebarSections.alreadyOnTop", defaultValue: "this item is already at the top of the sidebar", table: "SidebarSections", bundle: .module)
    }
    static var labelsOnlyOnALine: String {
        String(localized: "sidebarSections.labelsOnlyOnALine", defaultValue: "labels can be hidden only in a section shown on one line",
               table: "SidebarSections", bundle: .module)
    }
    static var notAnApp: String {
        String(localized: "sidebarSections.notAnApp", defaultValue: "only an app item can be hidden", table: "SidebarSections", bundle: .module)
    }
    static var untitledSection: String {
        String(localized: "sidebarSections.untitled", defaultValue: "Untitled section", table: "SidebarSections", bundle: .module)
    }
    static var workspacesSection: String {
        String(localized: "sidebarSections.workspaces", defaultValue: "Workspaces", table: "SidebarSections", bundle: .module)
    }
    static var notHideable: String {
        String(localized: "sidebarSections.notHideable", defaultValue: "only Projects and Recents can be hidden; remove this section instead",
               table: "SidebarSections", bundle: .module)
    }
    static var alreadyHidden: String {
        String(localized: "sidebarSections.alreadyHidden", defaultValue: "this section is already hidden", table: "SidebarSections", bundle: .module)
    }
    static var noneHidden: String {
        String(localized: "sidebarSections.noneHidden", defaultValue: "no sidebar section is hidden", table: "SidebarSections", bundle: .module)
    }
}
