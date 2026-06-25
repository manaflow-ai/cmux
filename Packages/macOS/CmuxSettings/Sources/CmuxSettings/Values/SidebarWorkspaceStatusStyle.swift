import Foundation

/// How extension-sidebar workspace rows present their agent status.
public enum SidebarWorkspaceStatusStyle: String, CaseIterable, Sendable, SettingCodable {
    /// The default presentation: render the status sentence below the title.
    case sentence

    /// Compact presentation: render a status dot on the title line.
    case dot
}
