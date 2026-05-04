extension GhosttyApp {
    func reloadSurfaceConfiguration(
        _ surface: ghostty_surface_t,
        soft: Bool = false,
        source: String = "unspecified"
    ) {
        _ = source
        if soft, let config {
            ghostty_surface_update_config(surface, config)
            GhosttyConfig.invalidateLoadCache()
            return
        }

        guard let newConfig = ghostty_config_new() else { return }
        _ = loadDefaultConfigFilesWithLegacyFallback(newConfig)
        ghostty_surface_update_config(surface, newConfig)
        GhosttyConfig.invalidateLoadCache()
        ghostty_config_free(newConfig)
    }
}
