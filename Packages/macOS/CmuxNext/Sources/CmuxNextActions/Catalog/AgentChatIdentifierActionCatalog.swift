/// Copy Agent Identifier (cx-s7004): a chat's acpmux session id, the id
/// cross-session messaging takes (`acpmux send <id>`, `cmux agent message <id>`).
nonisolated enum AgentChatIdentifierActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "agentChat.copyIdentifier",
                title: String(localized: "action.agentChat.copyIdentifier", defaultValue: "Copy Agent Identifier", bundle: .module),
                keywords: ["agent", "chat", "session", "identifier", "id", "acpmux", "message", "copy"], category: .agents,
                symbol: "at", surfaces: [.palette, .contextMenu], targets: [.tab, .workspace],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.clipboard), contextMenus: [
                    ActionSurfaceCatalog.p(.tab, .inspect, 506, folder: .copy), ActionSurfaceCatalog.p(.agentChat, .inspect, 1),
                ])
            ),
        ]
    }
}
