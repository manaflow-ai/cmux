/// View Chat Only: a Claude Code or Codex chat in a tab that shows it and follows the app that
/// runs it, without running, resuming or writing to it, until Take Over (acpmux `hub/watch.rs`).
/// One path for every entrypoint: an All chats row's menu (`chats.watch`), the palette, and
/// `cmux agent view <key>`, all through `ChatsOpenCoordinator.watch`.
nonisolated enum AgentChatViewActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "agentChat.view",
                title: String(localized: "action.agentChat.view", defaultValue: "View Chat Only", bundle: .module),
                keywords: ["agent", "chat", "session", "view", "watch", "read only", "claude", "codex", "take over"],
                category: .agents, symbol: "eye", surfaces: [.palette],
                arguments: [
                    ActionArgument(name: "key", title: String(localized: "argument.agentChat.key", defaultValue: "Chat", bundle: .module),
                                   kind: .string),
                ],
                cliName: "agent view",
                // The chat is named by its key (`claude-code:<id>`, `codex:<id>`); the All chats
                // row's View Only item is web content that calls the same opener.
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
        ]
    }
}
