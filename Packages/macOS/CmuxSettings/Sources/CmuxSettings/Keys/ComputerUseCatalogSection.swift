import Foundation

/// Settings for local computer-use tools attached to supported agent sessions.
public struct ComputerUseCatalogSection: SettingCatalogSection {
    /// Whether newly spawned terminals allow the agent wrappers to attach the local computer-use MCP server.
    ///
    /// On by default so an agent already has the computer-use tools the moment a
    /// user asks it to drive the machine. cmux eagerly starts the standalone
    /// helper without prompting; the first tool call presents onboarding when a
    /// required permission is missing. Accessibility and Screen Recording belong
    /// only to that helper identity, never to the main cmux process.
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
