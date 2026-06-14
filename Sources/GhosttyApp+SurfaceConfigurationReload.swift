extension GhosttyApp {
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
        let reloadColorScheme = preferredColorScheme ?? effectiveTerminalColorSchemePreference
        _ = loadDefaultConfigFilesWithLegacyFallback(
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

    private func finishSurfaceConfigurationReload(source: String, soft: Bool, mode: String) {
#if DEBUG
        cmuxDebugLog("surface.config.reload source=\(source) soft=\(soft) mode=\(mode)")
#endif
        GhosttyConfig.invalidateLoadCache()
        // Drop the mobile inherited-theme cache: it is derived from the parsed
        // GhosttyConfig that was just invalidated, so a surface-level reload that
        // changes palette/default colors must re-resolve it for paired phones.
        // This is independent of the `.ghosttyConfigDidReload` notification below
        // (whose observers read app-scoped state), so it is dropped directly.
        // `invalidateInheritedThemeCache()` is nonisolated + thread-safe, so this
        // is safe whether or not the reload path is on the main actor.
        MobileTerminalRenderObserver.shared.invalidateInheritedThemeCache()
        // Do not post .ghosttyConfigDidReload here. Its observers read the
        // app-scoped GhosttyApp.config, which this surface-only path leaves
        // unchanged to avoid desyncing the app and other surfaces.
    }
}
