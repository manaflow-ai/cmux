import Foundation

/// Visual treatment used for modifier-hold shortcut hints in the workspace sidebar.
public enum SidebarShortcutHintStyle: String, CaseIterable, Hashable, Sendable, SettingCodable {
    /// The existing frosted capsule treatment.
    case pill
    /// Text without a material, border, or shadow.
    case bare
}
