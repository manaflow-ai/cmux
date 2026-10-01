// The agent GUI (acpmux conversations): its window, a new conversation, and
// whether the Mac stays awake while an agent turn runs. Titles live in
// AgentGUIActions.xcstrings.

nonisolated extension ActionCatalog {
    static func agentGUIActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "agentGUI.openWindow",
                title: String(localized: "action.agentGUI.openWindow", defaultValue: "Agent Conversations", table: "AgentGUIActions", bundle: .module),
                keywords: ["agent", "chat", "acpmux", "conversation", "claude", "codex"], category: .agents, symbol: "bubble.left.and.bubble.right",
                surfaces: [.palette, .menu], cliName: "agent window", mainMenu: .window
            ),
            ActionDescriptor(
                id: "agentGUI.newConversation",
                title: String(localized: "action.agentGUI.newConversation", defaultValue: "New Agent Conversation", table: "AgentGUIActions", bundle: .module),
                keywords: ["agent", "chat", "acpmux", "new"], category: .agents, symbol: "square.and.pencil",
                surfaces: [.palette, .menu], cliName: "agent new", mainMenu: .file
            ),
            ActionDescriptor(
                id: "agentGUI.toggleKeepAwake",
                title: String(localized: "action.agentGUI.toggleKeepAwake", defaultValue: "Keep Mac Awake During Agent Turns", table: "AgentGUIActions", bundle: .module),
                keywords: ["agent", "sleep", "awake", "caffeinate", "power"], category: .agents, symbol: "cup.and.saucer",
                surfaces: [.palette], cliName: "agent keep-awake"
            ),
        ]
    }
}
