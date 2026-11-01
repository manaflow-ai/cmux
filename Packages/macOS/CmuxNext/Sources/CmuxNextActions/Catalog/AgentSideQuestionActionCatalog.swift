/// Ask a Side Question… (`/btw`): the focused chat's composer starts a side question, which opens
/// as a side session in the chat's one side pane. No default key (default hotkeys need a call).
/// Offered only while Debug Settings' Side sessions (/btw) is on (``ActionContext/sideSessions``).
nonisolated enum AgentSideQuestionActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "agentPane.sideQuestion",
                title: String(localized: "action.agentPane.sideQuestion", defaultValue: "Ask a Side Question…", bundle: .module),
                keywords: ["agent", "chat", "btw", "side", "question", "aside", "ask", "session"],
                category: .agents, symbol: "questionmark.bubble", surfaces: [.palette],
                requires: [.agentPaneFocused, .sideSessions], targets: [.pane],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .guiOnly)
            ),
        ]
    }
}
