// The chat's edge (the user, 2026-11-03, msg 20105): the palette turns the minimap (the rail of
// prompt ticks or the full map) off and on, and moves the rail between the chat's left and right
// edges. Each row shows a check while it is on. Both write `agentPane.display.*` in cmux.json, the
// rows Settings > Agent Chat shows (Chat Minimap, Prompt Rail Side). Titles in ActionCatalog.xcstrings.

nonisolated enum AgentChatRailActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "agentPane.display.showMinimap",
                title: String(localized: "action.agentPane.display.showMinimap", defaultValue: "Show Chat Minimap", bundle: .module),
                keywords: ["agent", "chat", "minimap", "rail", "tick", "ticks", "prompt rail", "map", "hide", "edge", "setting"],
                category: .settings, symbol: "sidebar.right", surfaces: [.palette],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .guiOnly)
            ),
            ActionDescriptor(
                id: "agentPane.display.railOnRight",
                title: String(localized: "action.agentPane.display.railOnRight", defaultValue: "Prompt Rail on Right Edge", bundle: .module),
                keywords: ["agent", "chat", "minimap", "rail", "tick", "ticks", "prompt rail", "side", "left", "right", "edge", "setting"],
                category: .settings, symbol: "arrow.left.and.right", surfaces: [.palette],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .guiOnly)
            ),
        ]
    }
}
