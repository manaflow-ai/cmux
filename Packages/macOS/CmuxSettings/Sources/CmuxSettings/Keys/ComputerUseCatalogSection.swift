import Foundation

/// Settings for local computer-use tools attached to supported agent sessions.
public struct ComputerUseCatalogSection: SettingCatalogSection {
    /// Whether newly spawned terminals allow the agent wrappers to attach the local computer-use MCP server.
    ///
    /// On by default so supported sessions can attach the tools without a
    /// second configuration switch. cmux may start the standalone helper
    /// quietly, but only a deliberate Settings permission/setup action presents
    /// onboarding. Agent tool calls and status probes never authorize a TCC
    /// prompt. Accessibility and Screen Recording belong only to that helper
    /// identity, never to the main cmux process.
    public let enabled = JSONKey<Bool>(
        id: "computerUse.enabled",
        defaultValue: true
    )

    /// Whether the dedicated computer-use status item may appear in the menu bar.
    public let showInMenuBar = JSONKey<Bool>(
        id: "computerUse.showInMenuBar",
        defaultValue: true
    )

    /// Creates the computer-use catalog section with the shipped defaults.
    public init() {}
}
