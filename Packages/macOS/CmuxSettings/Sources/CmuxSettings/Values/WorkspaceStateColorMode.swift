import Foundation

/// How agent-state colors interact with manually assigned workspace colors.
public enum WorkspaceStateColorMode: String, CaseIterable, Sendable, SettingCodable {
    /// Use the configured agent-state color instead of any manual workspace color.
    case replace
    /// Mix the configured agent-state color with the workspace's manual color.
    case blend
}
