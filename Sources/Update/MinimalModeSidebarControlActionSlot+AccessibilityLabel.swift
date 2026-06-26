import CmuxWindowing
import Foundation

extension MinimalModeSidebarControlActionSlot {
    /// User-facing accessibility label for the button. Resolved here in the app
    /// target so `String(localized:)` reads the app bundle's localized strings
    /// (including Japanese); keeping it out of `CmuxWindowing` avoids binding to
    /// the package bundle, which lacks these keys and would drop translations.
    var accessibilityLabel: String {
        switch self {
        case .toggleSidebar:
            return String(localized: "titlebar.sidebar.accessibilityLabel", defaultValue: "Toggle Sidebar")
        case .showNotifications:
            return String(localized: "titlebar.notifications.accessibilityLabel", defaultValue: "Notifications")
        case .newTab:
            return String(localized: "titlebar.newWorkspace.accessibilityLabel", defaultValue: "New Workspace")
        case .focusHistoryBack:
            return String(localized: "menu.history.focusBack", defaultValue: "Focus Back")
        case .focusHistoryForward:
            return String(localized: "menu.history.focusForward", defaultValue: "Focus Forward")
        }
    }
}
