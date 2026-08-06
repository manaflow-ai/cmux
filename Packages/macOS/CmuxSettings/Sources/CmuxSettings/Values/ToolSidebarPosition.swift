import Foundation

/// The horizontal edge where cmux presents its native tool sidebar.
public enum ToolSidebarPosition: String, CaseIterable, Sendable, SettingCodable {
    /// Place Files, Find, Vault, Feed, and Dock before the main workspace content.
    case left

    /// Place Files, Find, Vault, Feed, and Dock after the main workspace content.
    case right
}
