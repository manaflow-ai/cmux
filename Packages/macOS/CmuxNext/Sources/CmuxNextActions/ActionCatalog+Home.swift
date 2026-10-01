// Catalog rows for Home, the pinned sidebar row that shows the mux
// Messages screen (mux/DESIGN.md). Cmd+1 reaches it through
// `selectWorkspaceByNumber`; this action is the palette, menu and CLI path.

nonisolated extension ActionCatalog {
    static func homeActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "home.show",
                title: String(localized: "action.home.show", defaultValue: "Go to Home", bundle: .module),
                keywords: ["home", "mux", "messages", "orchestrator"], category: .window, symbol: "house",
                surfaces: [.palette, .keyboard, .menu], cliName: "home show",
                mainMenu: .file
            ),
        ]
    }
}
