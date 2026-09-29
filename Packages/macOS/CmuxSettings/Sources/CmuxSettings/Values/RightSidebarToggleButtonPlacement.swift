import Foundation

/// Where the persistent right-sidebar show/hide button lives
/// (`rightSidebar.toggleButton`).
///
/// Every visible placement keeps the button on screen while the right sidebar
/// is hidden, so the button can always reopen it.
public enum RightSidebarToggleButtonPlacement: String, CaseIterable, Sendable, SettingCodable {
    /// The window's top-trailing corner. The button keeps one screen position
    /// whether the sidebar is shown or hidden, and replaces the mode bar's
    /// close button while the sidebar is shown.
    case titlebar
    /// The trailing end of the top-right pane's tab bar, next to the tab bar
    /// action buttons. The button follows that pane's edge.
    case paneTabBar
    /// The trailing end of the left sidebar footer. Hidden while the left
    /// sidebar is hidden.
    case sidebarFooter
    /// No persistent button. The mode bar's close button and the shortcut
    /// still work.
    case hidden
}
