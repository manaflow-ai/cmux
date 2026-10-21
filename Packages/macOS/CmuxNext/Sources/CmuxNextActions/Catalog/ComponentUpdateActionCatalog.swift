// Update cmux Components…: one check of the app, cmux-tui, acpmux and the agent CLIs, and one
// Update All that runs each one's own update path (plans/cmux-next/server-updates-DESIGN.md 7).
// The app binds it in ComponentUpdates; the title lives in ActionCatalog.xcstrings.

nonisolated enum ComponentUpdateActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "palette.updateComponents",
                title: String(localized: "action.palette.updateComponents", defaultValue: "Update cmux Components…", bundle: .module),
                keywords: ["update", "version", "upgrade", "outdated", "cmux-tui", "acpmux", "daemon", "server", "agent", "cli", "status"],
                category: .settings, symbol: "arrow.triangle.2.circlepath.circle",
                surfaces: [.palette], cliName: "settings update-components"
            ),
        ]
    }
}
