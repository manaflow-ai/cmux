extension GhosttyApp {
    func reloadSurfaceConfiguration(
        _ surface: ghostty_surface_t,
        soft: Bool = false,
        source: String = "unspecified",
        remoteAppearanceOverride: String? = nil
    ) {
        let normalizedOverride = remoteAppearanceOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let overrideConfig = normalizedOverride?.isEmpty == false ? normalizedOverride : nil

        if soft, let config, overrideConfig == nil {
            ghostty_surface_update_config(surface, config)
            finishSurfaceConfigurationReload(source: source, soft: soft, mode: "soft")
            return
        }

        guard let newConfig = ghostty_config_new() else { return }
        _ = loadDefaultConfigFilesWithLegacyFallback(
            newConfig,
            remoteAppearanceOverride: overrideConfig
        )
        // Ghostty Surface.updateConfig derives its own surface state from the
        // passed config. The C API does not retain this temporary pointer.
        ghostty_surface_update_config(surface, newConfig)
        finishSurfaceConfigurationReload(
            source: source,
            soft: soft,
            mode: overrideConfig == nil ? "full" : "full+remote"
        )
        ghostty_config_free(newConfig)
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
