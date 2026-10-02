// Catalog rows for one domain. Titles live in Localizable.xcstrings (en, ja).

nonisolated extension ActionCatalog {
    static func agentsActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "palette.newAgentChat",
                title: String(localized: "action.palette.newAgentChat", defaultValue: "New Agent Chat", bundle: .module),
                keywords: ["agent", "chat", "ai", "acpmux"], category: .agents, symbol: "bubble.left.and.text.bubble.right",
                surfaces: [.palette, .menu, .contextMenu], targets: [.pane], cliName: "agent new-chat", mainMenu: .file
            ),
            ActionDescriptor(
                id: "agentPane.toggleInspector",
                title: String(localized: "action.agentPane.toggleInspector", defaultValue: "Show ACP Inspector", bundle: .module),
                keywords: ["agent", "acp", "acpmux", "inspector", "log", "debug"], category: .agents, symbol: "list.bullet.rectangle",
                surfaces: [.palette], targets: [.pane], cliName: "agent toggle-acp-inspector"
            ),
            ActionDescriptor(
                id: "palette.openTerminalChatView",
                title: String(localized: "action.palette.openTerminalChatView", defaultValue: "Open Terminal as Chat", bundle: .module),
                keywords: ["agent", "chat"], category: .agents, symbol: "text.bubble", surfaces: [.palette],
                requires: [.terminalFocused], cliName: "agent open-terminal-as-chat"
            ),
            ActionDescriptor(
                id: "palette.launchClaudeTeams",
                title: String(localized: "action.palette.launchClaudeTeams", defaultValue: "Launch Claude Teams", bundle: .module),
                keywords: ["agent", "claude", "team"], category: .agents, symbol: "person.3", surfaces: [.palette],
                cliName: "agent launch-claude-teams"
            ),
            ActionDescriptor(
                id: "palette.launchCodexTeams",
                title: String(localized: "action.palette.launchCodexTeams", defaultValue: "Launch Codex Teams", bundle: .module),
                keywords: ["agent", "codex", "team"], category: .agents, symbol: "person.3.fill", surfaces: [.palette],
                cliName: "agent launch-codex-teams"
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationRight",
                title: String(localized: "action.palette.forkAgentConversationRight", defaultValue: "Fork Conversation to the Right", bundle: .module),
                keywords: ["agent", "fork"], category: .agents, symbol: "arrow.triangle.branch",
                surfaces: [.palette, .contextMenu], requires: [.terminalFocused],
                cliName: "agent fork-conversation-to-right"
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationLeft",
                title: String(localized: "action.palette.forkAgentConversationLeft", defaultValue: "Fork Conversation to the Left", bundle: .module),
                keywords: ["agent", "fork"], category: .agents, symbol: "arrow.triangle.branch",
                surfaces: [.palette, .contextMenu], requires: [.terminalFocused],
                cliName: "agent fork-conversation-to-left"
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationTop",
                title: String(localized: "action.palette.forkAgentConversationTop", defaultValue: "Fork Conversation Above", bundle: .module),
                keywords: ["agent", "fork"], category: .agents, symbol: "arrow.triangle.branch",
                surfaces: [.palette, .contextMenu], requires: [.terminalFocused],
                cliName: "agent fork-conversation-above"
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationBottom",
                title: String(localized: "action.palette.forkAgentConversationBottom", defaultValue: "Fork Conversation Below", bundle: .module),
                keywords: ["agent", "fork"], category: .agents, symbol: "arrow.triangle.branch",
                surfaces: [.palette, .contextMenu], requires: [.terminalFocused],
                cliName: "agent fork-conversation-below"
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationNewTab",
                title: String(localized: "action.palette.forkAgentConversationNewTab", defaultValue: "Fork Conversation to New Tab", bundle: .module),
                keywords: ["agent", "fork"], category: .agents, symbol: "arrow.triangle.branch",
                surfaces: [.palette, .contextMenu], requires: [.terminalFocused],
                cliName: "agent fork-conversation-to-new-tab"
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationNewWorkspace",
                title: String(localized: "action.palette.forkAgentConversationNewWorkspace", defaultValue: "Fork Conversation to New Workspace", bundle: .module),
                keywords: ["agent", "fork"], category: .agents, symbol: "arrow.triangle.branch",
                surfaces: [.palette, .contextMenu], requires: [.terminalFocused],
                cliName: "agent fork-conversation-to-new-workspace"
            ),
            ActionDescriptor(
                id: "palette.computerUse.setup",
                title: String(localized: "action.palette.computerUse.setup", defaultValue: "Computer Use Setup", bundle: .module),
                keywords: ["agent", "automation"], category: .agents, symbol: "cursorarrow.click.2",
                surfaces: [.palette], cliName: "agent computer-use-setup"
            ),
            ActionDescriptor(
                id: "palette.computerUse.accessibility",
                title: String(localized: "action.palette.computerUse.accessibility", defaultValue: "Grant Accessibility Access", bundle: .module),
                keywords: ["agent", "permissions", "tcc"], category: .agents, symbol: "accessibility",
                surfaces: [.palette], cliName: "agent grant-accessibility-access"
            ),
            ActionDescriptor(
                id: "palette.computerUse.screenRecording",
                title: String(localized: "action.palette.computerUse.screenRecording", defaultValue: "Grant Screen Recording Access", bundle: .module),
                keywords: ["agent", "permissions", "tcc"], category: .agents, symbol: "record.circle",
                surfaces: [.palette], cliName: "agent grant-screen-recording-access"
            ),
            ActionDescriptor(
                id: "computerUseFocus",
                title: String(localized: "action.computerUseFocus", defaultValue: "Focus Computer Use", bundle: .module),
                keywords: ["agent", "automation"], category: .agents, symbol: "cursorarrow.rays", surfaces: [.menu],
                cliName: "agent focus-computer-use", mainMenu: .file
            ),
            ActionDescriptor(
                id: "computerUseFocusCallingTerminal",
                title: String(localized: "action.computerUseFocusCallingTerminal", defaultValue: "Focus Calling Terminal", bundle: .module),
                keywords: ["agent", "automation"], category: .agents, symbol: "terminal", surfaces: [.menu],
                cliName: "agent focus-calling-terminal", mainMenu: .file
            ),
            ActionDescriptor(
                id: "computerUseStop",
                title: String(localized: "action.computerUseStop", defaultValue: "Stop Computer Use", bundle: .module),
                keywords: ["agent", "automation"], category: .agents, symbol: "stop.circle", surfaces: [.menu],
                cliName: "agent stop-computer-use", mainMenu: .file
            ),
        ]
    }
}
