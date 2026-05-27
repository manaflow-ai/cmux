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
        if let surface {
            applySurfaceColorScheme()
            reloadSurfaceConfiguration(surface, true, source)
        }
        refreshHostBackground()
        forceRefresh(forceRefreshReason)
    }
}
