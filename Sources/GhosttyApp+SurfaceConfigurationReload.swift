extension GhosttyApp {
    @MainActor
    func reloadSurfaceConfiguration(
        _ surface: ghostty_surface_t,
        soft: Bool = false,
        source: String = "unspecified",
        preferredColorScheme: GhosttyConfig.ColorSchemePreference? = nil
    ) {
        if soft, let config {
            ghostty_surface_update_config(surface, config)
            finishSurfaceConfigurationReload(source: source, soft: soft, mode: "soft")
            return
        }

        guard let newConfig = ghostty_config_new() else { return }
        // The default color scheme + the layered config loader moved to
        // `engineRuntime` (CmuxTerminal); this surface-only reload drives them
        // there while leaving the app-scoped `config` handle unchanged.
        let reloadColorScheme = preferredColorScheme ?? engineRuntime.effectiveTerminalColorSchemePreference
        _ = engineRuntime.loadDefaultConfigFilesWithLegacyFallback(
            newConfig,
            preferredColorScheme: reloadColorScheme,
            conditionalThemeColorScheme: GhosttyConfig.currentColorSchemePreference()
        )
        // Ghostty Surface.updateConfig derives its own surface state from the
        // passed config. The C API does not retain this temporary pointer.
        ghostty_surface_update_config(surface, newConfig)
        finishSurfaceConfigurationReload(source: source, soft: soft, mode: "full")
        ghostty_config_free(newConfig)
    }

    /// Facade restored after the engine-runtime move: `GhosttyApp.shared`
    /// callers reload config through here; the implementation lives on
    /// `engineRuntime` (CmuxTerminal).
    @MainActor
    func reloadConfiguration(
        soft: Bool = false,
        source: String,
        reloadSettingsFromFile: Bool = true,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference? = nil
    ) {
        engineRuntime.reloadConfiguration(
            soft: soft,
            source: source,
            reloadSettingsFromFile: reloadSettingsFromFile,
            preferredColorScheme: preferredColorScheme
        )
    }

    private func finishSurfaceConfigurationReload(source: String, soft: Bool, mode: String) {
#if DEBUG
        cmuxDebugLog("surface.config.reload source=\(source) soft=\(soft) mode=\(mode)")
#endif
        GhosttyConfig.invalidateLoadCache()
        // Do not post .ghosttyConfigDidReload here. Its observers read the
        // app-scoped GhosttyApp.config, which this surface-only path leaves
        // unchanged to avoid desyncing the app and other surfaces.
    }
}
