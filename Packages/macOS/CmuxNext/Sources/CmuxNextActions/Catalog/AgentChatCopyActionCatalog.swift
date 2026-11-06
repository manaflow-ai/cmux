// Clipboard actions for the focused agent chat. These stay in the palette so each potentially
// sensitive output has an explicit, named choice; the native chat menu keeps its own Copy submenu.
nonisolated enum AgentChatCopyActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        let focusedChat: ActionContext = [.agentPaneFocused]
        let guiClipboard = ActionSurfacePlan(cli: .exempt(.clipboard), contextMenuExemption: .guiOnly)
        return [
            ActionDescriptor(
                id: "agentChat.copyName",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.agentChat.copyName") + "\u{E002}" + String(localized: "action.agentChat.copyName", defaultValue: "Copy Agent Name", bundle: .module)),
                keywords: ["agent", "chat", "harness", "name", "provider", "copy"], category: .agents,
                symbol: "person.text.rectangle", surfaces: [.palette], requires: focusedChat, targets: [.pane],
                surfacePlan: guiClipboard
            ),
            ActionDescriptor(
                id: "agentChat.copyHarnessSessionID",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.agentChat.copyHarnessSessionID") + "\u{E002}" + String(localized: "action.agentChat.copyHarnessSessionID", defaultValue: "Copy Harness Session ID", bundle: .module)),
                keywords: ["agent", "chat", "harness", "session", "id", "identifier", "claude", "codex", "copy"],
                category: .agents, symbol: "number", surfaces: [.palette], requires: focusedChat, targets: [.pane],
                surfacePlan: guiClipboard
            ),
            ActionDescriptor(
                id: "agentChat.copyConversation",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.agentChat.copyConversation") + "\u{E002}" + String(localized: "action.agentChat.copyConversation", defaultValue: "Copy Conversation as Markdown", bundle: .module)),
                keywords: ["agent", "chat", "conversation", "transcript", "markdown", "messages", "copy"],
                category: .agents, symbol: "text.quote", surfaces: [.palette], requires: focusedChat, targets: [.pane],
                surfacePlan: guiClipboard
            ),
            ActionDescriptor(
                id: "agentChat.copySessionDetails",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.agentChat.copySessionDetails") + "\u{E002}" + String(localized: "action.agentChat.copySessionDetails", defaultValue: "Copy Session Details", bundle: .module)),
                keywords: ["agent", "chat", "session", "details", "metadata", "cwd", "host", "copy"],
                category: .agents, symbol: "doc.text.magnifyingglass", surfaces: [.palette], requires: focusedChat, targets: [.pane],
                surfacePlan: guiClipboard
            ),
            ActionDescriptor(
                id: "agentChat.copyWorkingDirectory",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.agentChat.copyWorkingDirectory") + "\u{E002}" + String(localized: "action.agentChat.copyWorkingDirectory", defaultValue: "Copy Working Directory", bundle: .module)),
                keywords: ["agent", "chat", "session", "cwd", "directory", "folder", "path", "copy"],
                category: .agents, symbol: "folder", surfaces: [.palette], requires: focusedChat, targets: [.pane],
                surfacePlan: guiClipboard
            ),
            ActionDescriptor(
                id: "agentChat.copyHost",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.agentChat.copyHost") + "\u{E002}" + String(localized: "action.agentChat.copyHost", defaultValue: "Copy Chat Host", bundle: .module)),
                keywords: ["agent", "chat", "session", "host", "machine", "remote", "copy"],
                category: .agents, symbol: "network", surfaces: [.palette], requires: focusedChat, targets: [.pane],
                surfacePlan: guiClipboard
            ),
            ActionDescriptor(
                id: "agentChat.copySessionFilePaths",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.agentChat.copySessionFilePaths") + "\u{E002}" + String(localized: "action.agentChat.copySessionFilePaths", defaultValue: "Copy Session File Paths", bundle: .module)),
                keywords: ["agent", "chat", "session", "files", "paths", "claude.json", "settings.json", "config.toml", "transcript", "jsonl", "copy"],
                category: .agents, symbol: "doc.on.doc", surfaces: [.palette], requires: focusedChat, targets: [.pane],
                surfacePlan: guiClipboard
            ),
            ActionDescriptor(
                id: "agentChat.copyTranscriptFile",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.agentChat.copyTranscriptFile") + "\u{E002}" + String(localized: "action.agentChat.copyTranscriptFile", defaultValue: "Copy Transcript File", bundle: .module)),
                keywords: ["agent", "chat", "session", "transcript", "jsonl", "rollout", "raw", "claude", "codex", "copy"],
                category: .agents, symbol: "doc.plaintext", surfaces: [.palette], requires: focusedChat, targets: [.pane],
                surfacePlan: guiClipboard
            ),
            ActionDescriptor(
                id: "agentChat.copyHarnessConfigFile",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.agentChat.copyHarnessConfigFile") + "\u{E002}" + String(localized: "action.agentChat.copyHarnessConfigFile", defaultValue: "Copy Harness Config File", bundle: .module)),
                keywords: ["agent", "chat", "harness", "config", "claude.json", "config.toml", "claude", "codex", "json", "copy"],
                category: .agents, symbol: "gearshape", surfaces: [.palette], requires: focusedChat, targets: [.pane],
                surfacePlan: guiClipboard
            ),
            ActionDescriptor(
                id: "agentChat.copyHarnessSettingsFile",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.agentChat.copyHarnessSettingsFile") + "\u{E002}" + String(localized: "action.agentChat.copyHarnessSettingsFile", defaultValue: "Copy Harness Settings File", bundle: .module)),
                keywords: ["agent", "chat", "harness", "settings", "settings.json", "claude", "json", "copy"],
                category: .agents, symbol: "slider.horizontal.3", surfaces: [.palette], requires: focusedChat, targets: [.pane],
                surfacePlan: guiClipboard
            ),
            ActionDescriptor(
                id: "agentChat.copyAcpmuxSessionFile",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.agentChat.copyAcpmuxSessionFile") + "\u{E002}" + String(localized: "action.agentChat.copyAcpmuxSessionFile", defaultValue: "Copy acpmux Session File", bundle: .module)),
                keywords: ["agent", "chat", "acpmux", "session", "session.json", "json", "record", "copy"],
                category: .agents, symbol: "curlybraces", surfaces: [.palette], requires: focusedChat, targets: [.pane],
                surfacePlan: guiClipboard
            ),
        ]
    }
}
