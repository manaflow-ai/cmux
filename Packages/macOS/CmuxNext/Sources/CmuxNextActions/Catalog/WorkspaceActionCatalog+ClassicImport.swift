// Moving from cmux classic (docs/cmux-next/classic-to-next.md). Titles live in
// ActionCatalog.xcstrings.

nonisolated extension WorkspaceActionCatalog {
    static func classicImportActions() -> [ActionDescriptor] {
        // Started by the person (palette or CLI). The launch runs the same
        // migration once by itself (classic-migration-DESIGN.md); this action
        // brings back what is not open here, never a duplicate.
        var importClassic = ActionDescriptor(
            id: "workspace.importClassic",
            title: String(localized: "action.workspace.importClassic", defaultValue: "Import Workspaces from Classic cmux", bundle: .module),
            keywords: ["classic", "import", "migrate", "session", "restore"], category: .workspace,
            symbol: "square.and.arrow.down", surfaces: [.palette], cliName: "workspace import-classic"
        )
        // One import opens every saved workspace, longer than a terminal
        // start: a caller that timed out and retried would open them twice.
        importClassic.waitsForResult = true
        // Palette, CLI, MCP and scripts all wait on the same native preview;
        // no caller-provided confirmation bypasses it.
        importClassic.waitsForPerson = true
        return [importClassic]
    }
}
