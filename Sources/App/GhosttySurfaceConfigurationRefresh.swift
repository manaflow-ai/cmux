@MainActor
enum GhosttySurfaceConfigurationRefresh {
    nonisolated static let forceRefreshReason = "appDelegate.refreshAfterGhosttyConfigReload"

    static func applyAfterAppConfigReload(
        to surface: ghostty_surface_t?,
        source: String,
        reloadSurfaceConfiguration: (ghostty_surface_t, Bool, String) -> Void,
        refreshHostBackground: () -> Void,
        forceRefresh: (String) -> Void
    ) {
        if let surface {
            reloadSurfaceConfiguration(surface, true, source)
        }
        refreshHostBackground()
        forceRefresh(forceRefreshReason)
    }
}
