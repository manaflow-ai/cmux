import Foundation

/// Settings for local computer-use tools attached to supported agent sessions.
public struct ComputerUseCatalogSection: SettingCatalogSection {
    /// Whether newly spawned terminals allow the agent wrappers to attach the local computer-use MCP server.
    ///
    /// Off by default: computer use drives real apps and needs its own macOS
    /// Accessibility / Screen Recording grants, so it must be opt-in. Until the
    /// user enables it in Settings > Computer Use, agent launches carry no
    /// computer-use tools and nothing can trigger a permission prompt.
    public let enabled = JSONKey<Bool>(
        id: "computerUse.enabled",
        defaultValue: false
    )

    /// Whether the dedicated computer-use status item may appear in the menu bar.
    public let showInMenuBar = JSONKey<Bool>(
        id: "computerUse.showInMenuBar",
        defaultValue: true
    )

    /// Creates the computer-use catalog section with the shipped defaults.
    public init() {}
}
