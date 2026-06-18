import Foundation

/// Which side of the window the vertical tab sidebar appears on.
public enum SidebarSideOption: String, CaseIterable, Sendable, SettingCodable {
    case left
    case right
}
