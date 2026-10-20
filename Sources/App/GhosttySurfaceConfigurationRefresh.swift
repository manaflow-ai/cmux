@MainActor
enum GhosttySurfaceConfigurationRefresh {
    nonisolated static let forceRefreshReason = "appDelegate.refreshAfterGhosttyConfigReload"
    nonisolated static let cmuxThemeReloadLegacySource = "distributed.cmux.themes"
    nonisolated static let cmuxThemeReloadPreviewSource = "distributed.cmux.themes.preview"
    nonisolated static let cmuxThemeReloadFinalSource = "distributed.cmux.themes.final"
    nonisolated static let cmuxThemePreviewReloadDebounceMilliseconds = 180

    nonisolated static func cmuxThemeReloadSource(phase: String?) -> String {
        switch phase {
        case "final", "apply":
            return cmuxThemeReloadFinalSource
        case "preview":
            return cmuxThemeReloadPreviewSource
        default:
            return cmuxThemeReloadLegacySource
        }
    }

    nonisolated static func shouldDebounceCmuxThemeReload(source: String) -> Bool {
        switch source {
        case cmuxThemeReloadLegacySource, cmuxThemeReloadPreviewSource:
            return true
        default:
            return false
        }
    }

    nonisolated static func isCmuxThemeReloadSource(_ source: String) -> Bool {
        switch source {
        case cmuxThemeReloadLegacySource, cmuxThemeReloadPreviewSource, cmuxThemeReloadFinalSource:
            return true
        default:
            return false
        }
    }

    static func applyAfterAppConfigReload(
        to surface: ghostty_surface_t?,
        source: String,
        reloadSurfaceConfiguration: (ghostty_surface_t, Bool, String) -> Void,
        applySurfaceColorScheme: () -> Void,
        refreshHostBackground: () -> Void,
        forceRefresh: (String) -> Void
    ) {
        applyConfigurationReload(
            to: surface,
            soft: true,
            source: source,
            redrawReason: forceRefreshReason,
            reloadSurfaceConfiguration: reloadSurfaceConfiguration,
            applySurfaceColorScheme: applySurfaceColorScheme,
            refreshHostBackground: refreshHostBackground,
            forceRefresh: forceRefresh
        )
    }

    static func applyConfigurationReload(
        to surface: ghostty_surface_t?,
        soft: Bool,
        source: String,
        redrawReason: String,
        reloadSurfaceConfiguration: (ghostty_surface_t, Bool, String) -> Void,
        applySurfaceColorScheme: () -> Void,
        refreshHostBackground: () -> Void,
        forceRefresh: (String) -> Void
    ) {
        if let surface {
            reloadSurfaceConfiguration(surface, soft, source)
            // The scheme must resolve against the newly installed config. Applying
            // it to the stale config can emit an old background before the reload,
            // pairing that background with the new foreground (issues #8938, #9588).
            applySurfaceColorScheme()
        }
        refreshHostBackground()
        forceRefresh(redrawReason)
    }
}
