// Tile Subagents: the focused chat's running subagents, each in a pane of its own stacked right of
// the chat (CmuxNextApp SubagentBeside). A row's click opens one subagent as a tab beside the chat;
// this is the explicit tiled alternative. Titles live in ActionCatalog.xcstrings.

nonisolated enum AgentSubagentActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "agentChat.tileSubagents",
                title: String(localized: "action.agentChat.tileSubagents", defaultValue: "Tile Subagents", bundle: .module),
                keywords: ["subagents", "agents", "tile", "stack", "panes", "split", "zellij", "chat"],
                category: .agents, symbol: "rectangle.split.1x2", surfaces: [.palette],
                requires: [.agentPaneFocused], targets: [.pane],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .guiOnly)
            ),
        ]
    }
}
