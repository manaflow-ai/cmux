import Foundation

/// Dynamic argument lists for the focused agent chat's configuration actions.
///
/// The App supplies the values from the connected acpmux snapshot. Keeping the
/// source names in the shared Actions module lets the palette, CLI argument
/// completion and MCP schema use one vocabulary without making the catalog
/// depend on the agent-pane UI.
public nonisolated extension ActionSuggestions {
    /// Models currently advertised by the focused harness.
    static let agentModels = "agentModels"
    /// Effort/config values currently advertised by the focused harness.
    static let agentEfforts = "agentEfforts"
    /// Modes currently advertised by the focused harness.
    static let agentModes = "agentModes"
}
