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

    /// Key hints: clickable key hints (`ctrl+o to expand`) that Claude Code,
    /// Codex, or OpenCode prints in a terminal pane. A click sends those keys
    /// to the agent. Off by default while the hints are dogfooded.
    public let keyHints = DefaultsKey<Bool>(
        id: "agentActions.keyHints",
        defaultValue: true,
        userDefaultsKey: "agentActionsKeyHintsEnabled"
    )

    /// At-rest marker style for detected clickable hints.
    public let keyHintRestStyle = DefaultsKey<AgentKeyHintRestStyle>(
        id: "agentActions.keyHintRestStyle",
        defaultValue: .dotted,
        userDefaultsKey: "agentActionsKeyHintRestStyle"
    )

    public init() {}
}
