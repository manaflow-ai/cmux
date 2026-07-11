import Foundation
import CmuxTerminal

extension GhosttyApp {
    @MainActor
    func updateAppConfigurationSurrenderingMobileViewportFontFits(
        _ updatedConfig: ghostty_config_t,
        source: String
    ) {
        let reason = "app.reloadConfig.\(source)"
        let configuredFontPointSize = configuredFontPointSize(from: updatedConfig)
        let prepared = AppDelegate.shared?
            .prepareTerminalSurfaceFontFitsForGhosttyAppConfigurationReload(
                reason: reason
            ) ?? []
        ghostty_app_update_config(app, updatedConfig)
        AppDelegate.shared?.finishTerminalSurfaceFontFitsAfterGhosttyAppConfigurationReload(
            prepared,
            configuredFontPointSize: configuredFontPointSize,
            reason: reason
        )
        // The scheduled per-surface refresh preserves this fitted state. Only
        // an independent surface-action reload acquires another lease.
    }

    @MainActor
    func reloadSurfaceConfigurationSurrenderingMobileViewportFontFit(
        _ surface: ghostty_surface_t,
        terminalSurface: TerminalSurface?,
        soft: Bool,
        source: String,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        guard let terminalSurface else {
            reloadSurfaceConfiguration(
                surface,
                soft: soft,
                source: source,
                preferredColorScheme: preferredColorScheme
            )
            return
        }
        terminalSurface.withMobileViewportFontFitSurrenderedForConfigurationReload(
            reason: "surface.reloadConfig"
        ) {
            self.reloadSurfaceConfiguration(
                surface,
                soft: soft,
                source: source,
                preferredColorScheme: preferredColorScheme
            )
        }
    }

    func appearanceBackedColorSchemePreference() -> GhosttyConfig.ColorSchemePreference {
        if Thread.isMainThread {
            return GhosttyConfig.appearanceSyncColorSchemePreference(passedAppearance: nil).preference
        }
        return effectiveTerminalColorSchemePreference
    }

    @discardableResult
    func reloadSurfaceConfiguration(
        _ surface: ghostty_surface_t,
        soft: Bool = false,
        source: String = "unspecified",
        preferredColorScheme: GhosttyConfig.ColorSchemePreference? = nil
    ) -> Float? {
        if soft, let config {
            ghostty_surface_update_config(surface, config)
            finishSurfaceConfigurationReload(source: source, soft: soft, mode: "soft")
            return configuredFontPointSize(from: config)
        }

        guard let newConfig = ghostty_config_new() else { return nil }
        let reloadColorScheme = preferredColorScheme ?? effectiveTerminalColorSchemePreference
        let conditionalThemeColorScheme = appearanceBackedColorSchemePreference()
        _ = loadDefaultConfigFilesWithLegacyFallback(
            newConfig,
            preferredColorScheme: reloadColorScheme,
            conditionalThemeColorScheme: conditionalThemeColorScheme
        )
        // Ghostty Surface.updateConfig derives its own surface state from the
        // passed config. The C API does not retain this temporary pointer.
        ghostty_surface_update_config(surface, newConfig)
        let configuredFontPointSize = configuredFontPointSize(from: newConfig)
        finishSurfaceConfigurationReload(source: source, soft: soft, mode: "full")
        ghostty_config_free(newConfig)
        return configuredFontPointSize
    }

    private func configuredFontPointSize(from config: ghostty_config_t) -> Float? {
        var fontSize: Float32 = 0
        let key = "font-size"
        guard ghostty_config_get(
            config,
            &fontSize,
            key,
            UInt(key.lengthOfBytes(using: .utf8))
        ), fontSize.isFinite, fontSize > 0 else { return nil }
        return fontSize
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

extension AppDelegate {
    func prepareTerminalSurfaceFontFitsForGhosttyAppConfigurationReload(
        reason: String
    ) -> [(surface: TerminalSurface, lease: MobileViewportFontFitReloadLease?)] {
        var prepared: [(surface: TerminalSurface, lease: MobileViewportFontFitReloadLease?)] = []
        for surface in GhosttyApp.terminalSurfaceRegistry.allTerminalSurfaces() {
            let lease = surface.prepareMobileViewportFontFitForConfigurationReload(
                reason: reason
            )
            prepared.append((surface: surface, lease: lease))
        }
        return prepared
    }

    func finishTerminalSurfaceFontFitsAfterGhosttyAppConfigurationReload(
        _ prepared: [(surface: TerminalSurface, lease: MobileViewportFontFitReloadLease?)],
        configuredFontPointSize: Float?,
        reason: String
    ) {
        for entry in prepared {
            if let lease = entry.lease {
                entry.surface.finishMobileViewportFontFitConfigurationReload(
                    lease,
                    configuredFontPointSize: configuredFontPointSize,
                    reason: reason
                )
            } else {
                entry.surface.recordMobileViewportConfiguredFontPointSize(configuredFontPointSize)
            }
        }
    }
}
