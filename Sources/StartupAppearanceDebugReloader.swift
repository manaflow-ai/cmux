#if DEBUG
import AppKit
import CmuxAppKitSupportUI

/// App-target conformer for the package-owned Startup Appearance debug panel's
/// ``StartupAppearanceReloading`` seam.
///
/// It implements the panel's three app couplings against the live app-target
/// types the package cannot reference: the persisted appearance preference
/// (`AppearanceSettings.resolvedMode()`), the engine's startup-config cache
/// (`GhosttyConfig.invalidateLoadCache()`), and the running-app configuration
/// reload. The reload preserves the legacy fallback exactly: it prefers
/// `AppDelegate.shared`'s `reloadConfiguration` and falls back to
/// `GhosttyApp.shared`'s when no delegate is present, with
/// `reloadSettingsFromFile: false` to match the legacy panel.
///
/// DEBUG-only: the panel is `#if DEBUG`-gated, so this conformer is too. It holds
/// no new state and is constructed at the composition root, injected into the
/// package view through `DebugWindowsCoordinator.startupAppearanceDebugContentProvider`.
final class StartupAppearanceDebugReloader: StartupAppearanceReloading {
    func resolvedAppearanceMode() -> StartupAppearanceResolvedMode {
        switch AppearanceSettings.resolvedMode() {
        case .system, .auto:
            return .unspecified
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    func invalidateLoadCache() {
        GhosttyConfig.invalidateLoadCache()
    }

    func reloadConfiguration(source: String) {
        if let appDelegate = AppDelegate.shared {
            appDelegate.reloadConfiguration(
                source: source,
                reloadSettingsFromFile: false
            )
        } else {
            GhosttyApp.shared.reloadConfiguration(
                source: source,
                reloadSettingsFromFile: false
            )
        }
    }
}
#endif
