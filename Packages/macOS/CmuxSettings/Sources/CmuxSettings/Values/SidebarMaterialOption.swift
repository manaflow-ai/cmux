import Foundation

/// AppKit `NSVisualEffectView.Material` choice for the sidebar.
public enum SidebarMaterialOption: String, CaseIterable, Sendable, SettingCodable {
    case sidebar
    case titlebar
    case selection
    case menu
    case popover
    case headerView
    case sheet
    case windowBackground
    case hudWindow
    case fullScreenUI
    case toolTip
    case contentBackground
    case underWindowBackground
    case underPageBackground
}
