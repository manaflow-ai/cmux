import Foundation

/// AppKit `NSVisualEffectView.State` choice for the sidebar.
public enum SidebarStateOption: String, CaseIterable, Sendable, SettingCodable {
    case active
    case inactive
    case followWindow = "followsWindowActiveState"
}
