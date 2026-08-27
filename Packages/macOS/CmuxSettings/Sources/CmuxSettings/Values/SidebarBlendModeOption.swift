import Foundation

/// AppKit `NSVisualEffectView.BlendingMode` choice for the sidebar.
public enum SidebarBlendModeOption: String, CaseIterable, Sendable, SettingCodable {
    case behindWindow
    case withinWindow
}
