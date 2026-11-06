// The window backdrop (background art), reached by right-clicking the window's background or an
// agent chat's empty space.

nonisolated enum BackdropActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "appearance.changeBackground",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.appearance.changeBackground") + "\u{E002}" + String(localized: "action.appearance.changeBackground", defaultValue: "Change Background…", bundle: .module)),
                keywords: ["background", "wallpaper", "art", "painting", "backdrop", "appearance"],
                category: .settings, symbol: "photo", surfaces: [.palette, .contextMenu],
                cliName: "settings change-background",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [
                    ContextMenuPlacement(.agentChat, .identity, 0), ContextMenuPlacement(.windowBackground, .identity, 0),
                ])
            ),
        ]
    }
}
