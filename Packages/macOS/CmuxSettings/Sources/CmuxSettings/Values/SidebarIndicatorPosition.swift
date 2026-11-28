import Foundation

/// Which side of a sidebar workspace row a status indicator (the loading
/// spinner or the unread notification badge) appears on. `leading` shares the
/// left status slot before the title; `trailing` sits toward the close-button
/// corner.
public enum SidebarIndicatorPosition: String, CaseIterable, Sendable, SettingCodable {
    /// The left status slot, before the workspace title.
    case leading
    /// The right side of the row, toward the close-button corner.
    case trailing
}
