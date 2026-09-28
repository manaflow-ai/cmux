import Foundation

/// Clickable agent actions, one toggle per category (the `agentActions.*`
/// keys). Each category's buttons appear everywhere that category is offered.
public struct AgentActionsCatalogSection: SettingCatalogSection {
    /// Turn control: a Stop button over a terminal pane while Claude Code or
    /// Codex is working on a turn. Clicking it sends Escape, the agents' own
    /// interrupt key. Off by default while the button is dogfooded.
    public let turnControl = DefaultsKey<Bool>(
        id: "agentActions.turnControl",
        defaultValue: false,
        userDefaultsKey: "agentActionsTurnControlEnabled"
    )

    public init() {}
}
