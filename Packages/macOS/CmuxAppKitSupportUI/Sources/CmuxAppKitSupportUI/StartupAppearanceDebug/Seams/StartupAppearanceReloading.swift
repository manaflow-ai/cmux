#if canImport(AppKit)
#if DEBUG

/// The app-target seam the Startup Appearance debug panel drives to apply a
/// preview.
///
/// The panel's three app couplings are inverted behind this protocol so the
/// SwiftUI content can live in `CmuxAppKitSupportUI` without referencing the
/// application delegate, the running engine, or the app-target
/// `AppearanceSettings`/`GhosttyConfig`:
///
/// - ``resolvedAppearanceMode()`` reads the persisted appearance preference (the
///   legacy `AppearanceSettings.resolvedMode()`), normalized to the AppKit
///   appearance the panel applies for the "Stored App Setting" preview mode.
/// - ``invalidateLoadCache()`` clears the engine's cached startup config (the
///   legacy `GhosttyConfig.invalidateLoadCache()`) so the next reload re-resolves
///   the selected preview profile.
/// - ``reloadConfiguration(source:)`` reloads the running app through the same
///   Ghostty config-update path the legacy panel used (`AppDelegate.shared`'s
///   `reloadConfiguration` when present, otherwise `GhosttyApp.shared`'s), with
///   `reloadSettingsFromFile` fixed to `false` to match the legacy calls.
///
/// The app target constructs the conformer at the composition root and injects it
/// into the panel, so this package owns no reference to those app-target types.
@MainActor
public protocol StartupAppearanceReloading: AnyObject {
    /// The persisted appearance preference, normalized to the AppKit appearance
    /// the "Stored App Setting" preview mode applies.
    func resolvedAppearanceMode() -> StartupAppearanceResolvedMode

    /// Clears the engine's cached startup config so the next reload re-resolves
    /// the selected preview profile.
    func invalidateLoadCache()

    /// Reloads the running app's configuration through the Ghostty config-update
    /// path, tagged with the given telemetry `source` and matching the legacy
    /// `reloadSettingsFromFile: false` behavior.
    ///
    /// - Parameter source: The telemetry source string the legacy panel passed
    ///   (`"debug.startupAppearancePreview"` or `"debug.startupAppearanceRestore"`).
    func reloadConfiguration(source: String)
}

#endif
#endif
