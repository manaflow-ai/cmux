// Catalog rows for one domain. Titles live in Localizable.xcstrings (en, ja).

nonisolated enum AgentActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "palette.newAgentChat",
                title: String(localized: "action.palette.newAgentChat", defaultValue: "New Agent Chat", bundle: .module),
                keywords: ["agent", "chat", "ai", "acpmux"], defaultShortcut: Shortcut("i", modifiers: [.command, .shift]),
                category: .agents, symbol: "bubble.left.and.text.bubble.right",
                surfaces: [.palette, .keyboard, .menu, .contextMenu], targets: [.pane], cliName: "agent new-chat", mainMenu: .file
            ),
            {
                var quick = ActionDescriptor(
                    id: "palette.quickAgentChat",
                    title: String(localized: "action.palette.quickAgentChat", defaultValue: "Quick Agent Chat…", bundle: .module),
                    keywords: ["agent", "chat", "ai", "acpmux", "quick", "composer", "global", "hotkey", "summon"],
                    // Ctrl-Opt-Cmd-Space: clear of ChatGPT's and Claude's quick-entry defaults.
                    defaultShortcut: Shortcut(Shortcut.spaceKey, modifiers: [.control, .option, .command]),
                    category: .agents, symbol: "bubble.left.and.text.bubble.right.fill",
                    surfaces: [.palette, .keyboard, .menu], cliName: "agent quick", mainMenu: .file
                )
                // A floating composer over any app, so the key works while cmux is in the background.
                quick.isGlobalHotKey = true
                return quick
            }(),
            ActionDescriptor(
                id: "palette.toggleDictation",
                title: String(localized: "action.palette.toggleDictation", defaultValue: "Toggle Dictation", bundle: .module),
                keywords: ["dictation", "dictate", "voice", "speech", "microphone", "mic", "push to talk"],
                // Ctrl-Cmd-V: no terminal, shell or system meaning. Hold it to talk.
                defaultShortcut: Shortcut("v", modifiers: [.control, .command]),
                category: .agents, symbol: "mic", surfaces: [.palette, .keyboard, .menu],
                targets: [.pane], cliName: "agent toggle-dictation", mainMenu: .edit
            ),
            ActionDescriptor(
                id: "agentPane.continueIn",
                title: String(localized: "action.agentPane.continueIn", defaultValue: "Continue in…", bundle: .module),
                keywords: ["agent", "chat", "continue", "handoff", "claude", "codex", "acpmux"],
                category: .agents, symbol: "arrow.turn.up.right", surfaces: [.palette],
                requires: [.agentPaneFocused], targets: [.pane],
                // The named CLI handoff is owned by acpmux. This action is the
                // user-facing chooser that invokes that same frontend flow.
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .guiOnly)
            ),
            ActionDescriptor(
                id: "agentPane.createCheckpoint",
                title: String(localized: "action.agentPane.createCheckpoint", defaultValue: "Create checkpoint", bundle: .module),
                keywords: ["agent", "git", "snapshot", "checkpoint", "handoff"],
                category: .agents, symbol: "camera", surfaces: [.palette],
                requires: [.agentPaneFocused, .checkpointCaptureAvailable], targets: [.pane],
                // CLI/MCP capture runs headlessly through git.checkpoint.create.
                // This action opens its GUI approval checklist, without writing.
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .guiOnly)
            ),
            ActionDescriptor(
                id: "agentPane.searchChats",
                title: String(localized: "action.agentPane.searchChats", defaultValue: "Search Agent Chats", bundle: .module),
                keywords: ["agent", "chat", "search", "find", "sessions", "acpmux"],
                // Cmd-K searches chats only while an agent chat has the keyboard,
                // so the simulator's Cmd-K keeps its meaning.
                defaultShortcut: Shortcut("k", modifiers: [.command]),
                category: .agents, symbol: "magnifyingglass", surfaces: [.palette, .keyboard],
                requires: [.agentPaneFocused], targets: [.pane]
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
                id: "agentActivity.open",
                title: String(localized: "action.agentActivity.open", defaultValue: "Agent Activity", bundle: .module),
                keywords: ["agent", "computer use", "cua", "timeline", "screenshots", "automation"], category: .agents,
                symbol: "cursorarrow.click.2", surfaces: [.palette, .menu], cliName: "agent activity", mainMenu: .window
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
