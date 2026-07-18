import Foundation

/// Settings for local computer-use tools attached to supported agent sessions.
public struct ComputerUseCatalogSection: SettingCatalogSection {
    /// Whether newly spawned terminals allow the agent wrappers to attach the local computer-use MCP server.
    ///
    /// On by default so an agent already has the computer-use tools the moment a
    /// user asks it to drive the machine. This does not prompt for anything at
    /// launch: the tools stay dormant until actually invoked, and the first
    /// tool call presents cmux's onboarding if a required permission is missing.
    /// The bundled driver stays in cmux's responsibility chain, so macOS grants
    /// Accessibility and Screen Recording to cmux rather than a helper identity.
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
