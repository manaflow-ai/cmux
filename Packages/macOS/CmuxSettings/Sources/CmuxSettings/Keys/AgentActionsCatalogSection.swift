import Foundation

/// Clickable agent actions, one toggle per category (the `agentActions.*`
/// keys). Each category's buttons appear everywhere that category is offered.
public struct AgentActionsCatalogSection: SettingCatalogSection {
    /// Turn control: a Stop button over a terminal pane while Claude Code or
    /// Codex is working on a turn, which sends Escape, the agents' own
    /// interrupt key, and Compact and Resume in the Turns popover. Off by
    /// default while the buttons are dogfooded.
    public let turnControl = DefaultsKey<Bool>(
        id: "agentActions.turnControl",
        defaultValue: false,
        userDefaultsKey: "agentActionsTurnControlEnabled"
    )

    /// Prompt editing: while Claude Code has prompts waiting in its input
    /// queue, the terminal's agent pill offers Edit Queued, which sends Up to
    /// move them back into the input. Off by default while it is dogfooded.
    public let promptEditing = DefaultsKey<Bool>(
        id: "agentActions.promptEditing",
        defaultValue: false,
        userDefaultsKey: "agentActionsPromptEditingEnabled"
    )

    public init() {}
}
