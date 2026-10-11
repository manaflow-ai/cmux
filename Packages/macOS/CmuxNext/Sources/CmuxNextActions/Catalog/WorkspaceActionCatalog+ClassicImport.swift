// Moving from cmux classic (docs/cmux-next/classic-to-next.md). Titles live in
// ActionCatalog.xcstrings.

nonisolated extension WorkspaceActionCatalog {
    static func classicImportActions() -> [ActionDescriptor] {
        [
            // Started by the person (palette) or an agent (CLI), never on launch (cx-rwlb).
            ActionDescriptor(
                id: "workspace.importClassic",
                title: String(localized: "action.workspace.importClassic", defaultValue: "Import Workspaces from Classic cmux", bundle: .module),
                keywords: ["classic", "import", "migrate", "session", "restore"], category: .workspace,
                symbol: "square.and.arrow.down", surfaces: [.palette], cliName: "workspace import-classic", startsTerminal: true
            ),
        ]
    }
}
