import Foundation

/// AppKit `NSVisualEffectView.Material` choice for the sidebar.
public enum SidebarMaterialOption: String, CaseIterable, Sendable, SettingCodable {
    /// Native macOS Liquid Glass, with an AppKit material fallback on older systems.
    case liquidGlass
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
