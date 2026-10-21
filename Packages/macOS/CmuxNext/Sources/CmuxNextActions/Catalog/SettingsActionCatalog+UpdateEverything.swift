nonisolated extension SettingsActionCatalog {
    /// Update Everything (cx-1mbnu): the app, every connected machine's cmux and agent CLIs, then
    /// the threads. Only a person starts it: it restarts daemons, agents and the app.
    static var updateEverything: ActionDescriptor {
        var descriptor = ActionDescriptor(
            id: "updates.updateEverything",
            title: String(localized: "action.updates.updateEverything", defaultValue: "Update Everything…", bundle: .module),
            keywords: ["update", "upgrade", "machines", "agents", "claude", "codex", "daemon", "sparkle"], category: .settings,
            symbol: "arrow.triangle.2.circlepath.circle", surfaces: [.palette, .menu], mainMenu: .app
        )
        descriptor.isPersonOnly = true
        return descriptor
    }
}
