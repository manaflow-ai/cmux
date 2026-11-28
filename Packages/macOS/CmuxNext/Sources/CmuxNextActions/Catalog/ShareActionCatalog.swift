// "Share cmux…" (cx-7py7): the Share cmux modal with a message and the
// public download link. The palette, the Help menu and the "cmux Updated!"
// card's Share cmux row run this one action.

nonisolated enum ShareActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "app.shareCmux",
                title: String(localized: "action.app.shareCmux", defaultValue: "Share cmux…", bundle: .module),
                keywords: ["share", "invite", "friend", "recommend", "download link", "copy link", "tell a friend"],
                category: .settings, symbol: "square.and.arrow.up", surfaces: [.palette, .menu], mainMenu: .help,
                // A modal for a person to edit and copy; scripts have nothing to read back.
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
        ]
    }
}
