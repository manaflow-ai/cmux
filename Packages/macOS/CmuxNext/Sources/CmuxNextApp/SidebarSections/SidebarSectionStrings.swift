import CmuxNextSidebar
import Foundation

/// Strings of the sidebar section handlers (SidebarSections.xcstrings).
enum SidebarSectionStrings {
    static func rejected(_ reason: String) -> String {
        String(format: String(localized: "sidebarSections.rejected", defaultValue: "the sidebar layout refused this change (%@)",
                              table: "SidebarSections", bundle: .module), reason)
    }
    /// A band edit the sidebar document has no op for.
    static func describe(_ gap: SidebarDocStore.LayoutOpGap) -> String {
        switch gap {
        case .unsupported: notInDocument
        case .workspaceList: workspaceListStays
        case .unknownItem: noSuchItem
        case .rejected(let reject): rejected(reject.rawValue)
        }
    }
    static var notInDocument: String {
        String(localized: "sidebarSections.notInDocument", defaultValue: "this sidebar setting is not available in the new sidebar yet",
               table: "SidebarSections", bundle: .module)
    }
    static var workspaceListStays: String {
        String(localized: "sidebarSections.workspaceListStays", defaultValue: "the workspace list cannot be moved or removed",
               table: "SidebarSections", bundle: .module)
    }
    /// A Priority row action named a chat no acpmux lists any more.
    static var noSuchPriorityChat: String {
        String(localized: "sidebarSections.priority.noSuchChat", defaultValue: "that chat is no longer in the Priority view",
               table: "SidebarSections", bundle: .module)
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
    static var alreadyHidden: String {
        String(localized: "sidebarSections.alreadyHidden", defaultValue: "this section is already hidden", table: "SidebarSections", bundle: .module)
    }
    static var alreadyGrouped: String {
        String(localized: "sidebarSections.alreadyGrouped", defaultValue: "the list is already grouped this way", table: "SidebarSections", bundle: .module)
    }
    static var noBottomArea: String {
        String(localized: "sidebarSections.noBottomArea", defaultValue: "the sidebar has no bottom area; sections go above the workspaces",
               table: "SidebarSections", bundle: .module)
    }
    static var noneHidden: String {
        String(localized: "sidebarSections.noneHidden", defaultValue: "no sidebar section is hidden", table: "SidebarSections", bundle: .module)
    }
    static var cannotHide: String {
        String(localized: "sidebarSections.cannotHide", defaultValue: "this section cannot be hidden; remove it instead", table: "SidebarSections", bundle: .module)
    }
    // Right-click rows that name their change (cx-w1r5).
    static var hideLabel: String {
        String(localized: "sidebarSections.menu.hideLabel", defaultValue: "Hide Label", table: "SidebarSections", bundle: .module)
    }
    static var showLabel: String {
        String(localized: "sidebarSections.menu.showLabel", defaultValue: "Show Label", table: "SidebarSections", bundle: .module)
    }
    static var hideSectionTitle: String {
        String(localized: "sidebarSections.menu.hideSectionTitle", defaultValue: "Hide Section Title", table: "SidebarSections", bundle: .module)
    }
    static var showSectionTitle: String {
        String(localized: "sidebarSections.menu.showSectionTitle", defaultValue: "Show Section Title", table: "SidebarSections", bundle: .module)
    }
    static var collapseSection: String {
        String(localized: "sidebarSections.menu.collapseSection", defaultValue: "Collapse Section", table: "SidebarSections", bundle: .module)
    }
    static var expandSection: String {
        String(localized: "sidebarSections.menu.expandSection", defaultValue: "Expand Section", table: "SidebarSections", bundle: .module)
    }
    static func hide(named name: String) -> String {
        String(format: String(localized: "sidebarSections.menu.hideNamed", defaultValue: "Hide %@", table: "SidebarSections", bundle: .module), name)
    }
}
