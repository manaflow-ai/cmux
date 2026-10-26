import CmuxNextDesign
import CmuxNextSettings
import CmuxNextTerminal

// Launch calls for Ghostty: the theme, the keybinds, the config reload, the terminal hooks and the
// terminal theme settings (task 014, see Startup+Core.swift).
extension AppDelegate {
    /// Chrome colors derive from the Ghostty theme; load it before any window.
    func registerTheme() {
        ThemeBridge.start(store: ThemeScope.app.store)
    }

    /// The binding table's Ghostty keybinds, the live config reload, app-scoped Ghostty actions and the input-source keys.
    func registerTerminal(services: AppServices) {
        let ghosttyKeybinds = GhosttyKeybindSync(router: services.keyRouter)
        self.ghosttyKeybinds = ghosttyKeybinds
        ghosttyKeybinds.start()
        let ghosttyConfigLiveReload = GhosttyConfigLiveReload()
        self.ghosttyConfigLiveReload = ghosttyConfigLiveReload
        ghosttyConfigLiveReload.start()
        // App-scoped Ghostty actions (quit, toggle_visibility, ...) arrive with no surface.
        TerminalHooks(services: services).install()
        // The terminal key path's input-source switch keys, read off main now and on each activation.
        GhosttyRuntime.shared.inputSources.start(runner: services.work)
    }

    /// The terminal theme, the theme catalog and the chrome theme, following settings.
    func registerTerminalTheme(services: AppServices, settings: SettingsController) {
        services.terminalTheme.follow(settings)
        services.themes.start()
        services.themes.followChromeTheme(settings)
    }
}
