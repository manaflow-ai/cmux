// Catalog rows for one inventory domain. Titles live in Localizable.xcstrings (en, ja).

extension ActionCatalog {
    static func agentsActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "palette.newAgentChat",
                title: String(localized: "action.palette.newAgentChat", defaultValue: "New Agent Chat", bundle: .module),
                keywords: ["agent", "chat", "ai"], category: .agents, symbol: "bubble.left.and.text.bubble.right",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.openTerminalChatView",
                title: String(localized: "action.palette.openTerminalChatView", defaultValue: "Open Terminal as Chat", bundle: .module),
                keywords: ["agent", "chat"], category: .agents, symbol: "text.bubble", surfaces: [.palette],
                requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "palette.launchClaudeTeams",
                title: String(localized: "action.palette.launchClaudeTeams", defaultValue: "Launch Claude Teams", bundle: .module),
                keywords: ["agent", "claude", "team"], category: .agents, symbol: "person.3", surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.launchCodexTeams",
                title: String(localized: "action.palette.launchCodexTeams", defaultValue: "Launch Codex Teams", bundle: .module),
                keywords: ["agent", "codex", "team"], category: .agents, symbol: "person.3.fill", surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationRight",
                title: String(localized: "action.palette.forkAgentConversationRight", defaultValue: "Fork Conversation to the Right", bundle: .module),
                keywords: ["agent", "fork"], category: .agents, symbol: "arrow.triangle.branch",
                surfaces: [.palette, .contextMenu], requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationLeft",
                title: String(localized: "action.palette.forkAgentConversationLeft", defaultValue: "Fork Conversation to the Left", bundle: .module),
                keywords: ["agent", "fork"], category: .agents, symbol: "arrow.triangle.branch",
                surfaces: [.palette, .contextMenu], requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationTop",
                title: String(localized: "action.palette.forkAgentConversationTop", defaultValue: "Fork Conversation Above", bundle: .module),
                keywords: ["agent", "fork"], category: .agents, symbol: "arrow.triangle.branch",
                surfaces: [.palette, .contextMenu], requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationBottom",
                title: String(localized: "action.palette.forkAgentConversationBottom", defaultValue: "Fork Conversation Below", bundle: .module),
                keywords: ["agent", "fork"], category: .agents, symbol: "arrow.triangle.branch",
                surfaces: [.palette, .contextMenu], requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationNewTab",
                title: String(localized: "action.palette.forkAgentConversationNewTab", defaultValue: "Fork Conversation to New Tab", bundle: .module),
                keywords: ["agent", "fork"], category: .agents, symbol: "arrow.triangle.branch",
                surfaces: [.palette, .contextMenu], requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationNewWorkspace",
                title: String(localized: "action.palette.forkAgentConversationNewWorkspace", defaultValue: "Fork Conversation to New Workspace", bundle: .module),
                keywords: ["agent", "fork"], category: .agents, symbol: "arrow.triangle.branch",
                surfaces: [.palette, .contextMenu], requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "palette.computerUse.setup",
                title: String(localized: "action.palette.computerUse.setup", defaultValue: "Computer Use Setup", bundle: .module),
                keywords: ["agent", "automation"], category: .agents, symbol: "cursorarrow.click.2",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.computerUse.accessibility",
                title: String(localized: "action.palette.computerUse.accessibility", defaultValue: "Grant Accessibility Access", bundle: .module),
                keywords: ["agent", "permissions", "tcc"], category: .agents, symbol: "accessibility",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.computerUse.screenRecording",
                title: String(localized: "action.palette.computerUse.screenRecording", defaultValue: "Grant Screen Recording Access", bundle: .module),
                keywords: ["agent", "permissions", "tcc"], category: .agents, symbol: "record.circle",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "computerUseFocus",
                title: String(localized: "action.computerUseFocus", defaultValue: "Focus Computer Use", bundle: .module),
                keywords: ["agent", "automation"], category: .agents, symbol: "cursorarrow.rays", surfaces: [.menu]
            ),
            ActionDescriptor(
                id: "computerUseFocusCallingTerminal",
                title: String(localized: "action.computerUseFocusCallingTerminal", defaultValue: "Focus Calling Terminal", bundle: .module),
                keywords: ["agent", "automation"], category: .agents, symbol: "terminal", surfaces: [.menu]
            ),
            ActionDescriptor(
                id: "computerUseStop",
                title: String(localized: "action.computerUseStop", defaultValue: "Stop Computer Use", bundle: .module),
                keywords: ["agent", "automation"], category: .agents, symbol: "stop.circle", surfaces: [.menu]
            ),
        ]
    }
}
