// The window backdrop (background art), reached from an agent chat's empty-space menu.

nonisolated enum BackdropActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "appearance.changeBackground",
                title: String(localized: "action.appearance.changeBackground", defaultValue: "Change Background…", bundle: .module),
                keywords: ["background", "wallpaper", "art", "painting", "backdrop", "appearance"],
                category: .settings, symbol: "photo", surfaces: [.palette, .contextMenu],
                cliName: "settings change-background",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [ContextMenuPlacement(.agentChat, .identity, 0)])
            ),
        ]
    }
}
