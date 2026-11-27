public import AppKit
import CmuxNextCompat

/// `appearance.mode` on this app (Leo, 2026-11-21: "debate on the appearance; the functionality is
/// relatively obvious"): Light and Dark pin `NSApp.appearance`, Match System (the default) clears it
/// so macOS decides. The chrome and the terminals' light/dark theme pairs follow the effective
/// appearance (`GhosttyRuntime.applyColorScheme`). The app applies it at launch before any window,
/// then on every cmux.json change; the palette and CLI actions (`appearance.mode.<mode>`) apply it
/// at once. No state of its own: the app's `appearance` is the mode.
extension AppearanceModeSetting {
    /// The `NSAppearance` `mode` pins, nil for `system`.
    public static func appearance(_ mode: AppearanceMode) -> NSAppearance? {
        switch mode {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// The mode `app` shows now: its pinned appearance, `system` when none (or another one) is pinned.
    @MainActor public static func current(of app: NSApplication = .shared) -> AppearanceMode {
        switch app.appearance?.name {
        case NSAppearance.Name.aqua: .light
        case NSAppearance.Name.darkAqua: .dark
        default: .system
        }
    }

    /// Applies `mode` to `app`, writing `appearance` only on a change.
    @MainActor public static func apply(_ mode: AppearanceMode, to app: NSApplication = .shared) {
        let target = appearance(mode)
        if app.appearance?.name != target?.name { app.appearance = target }
    }

    /// Follows `settings.snapshot.appearanceMode` while `settings` lives. A value that did not change
    /// is not reapplied, so a `debug.appearance` override stays until the setting itself changes.
    @MainActor public static func follow(_ settings: SettingsController, app: NSApplication = .shared) {
        // task-owner: lives as long as the settings controller; event-driven (Observation)
        Task { [weak settings] in
            guard let settings else { return }
            await settings.waitForLoad(atLeast: 1)
            var last: AppearanceMode?
            for await mode in ObservationStream({ settings.snapshot.appearanceMode }) where mode != last {
                last = mode
                apply(mode, to: app)
            }
        }
    }
}
