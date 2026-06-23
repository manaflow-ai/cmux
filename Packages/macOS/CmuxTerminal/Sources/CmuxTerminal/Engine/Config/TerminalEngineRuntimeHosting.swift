public import CmuxTerminalCore
public import AppKit

/// The app-coupled policy reads and window-chrome effects the cold engine
/// runtime needs but that live in app-target god types this slice cannot move.
///
/// The legacy `GhosttyApp` engine orchestration called several app-target
/// settings/policy helpers and one window-chrome effect inline. Those types
/// (`KeyboardShortcutSettings`, `TerminalManagedGhosttySettings`,
/// `GhosttySurfaceConfigurationRefresh`, `cmuxReadableColorScheme`,
/// `AppWindowChromeComposition`, `telemetrySettings`, `SentrySDK`) are owned by
/// other refactor slices / are app-target only, so the runtime reaches them
/// through this injected seam instead of naming them.
///
/// Isolation: every member runs on the main thread in the legacy bodies (config
/// reload, appearance sync, and the window backdrop apply are all main-driven),
/// so the seam is `@MainActor`.
///
/// TODO(refactor): the app target must provide a concrete conformer wiring these
/// to `KeyboardShortcutSettings.settingsFileStore.reload()`,
/// `TerminalManagedGhosttySettings.ghosttyConfigContents()`,
/// `GhosttySurfaceConfigurationRefresh.isCmuxThemeReloadSource(_:)`,
/// `cmuxReadableColorScheme(for:)`, `AppWindowChromeComposition().…apply(plan:to:)`,
/// `telemetrySettings.enabledForCurrentLaunch`, and `SentrySDK.capture(...)` /
/// `sentryCaptureError(...)`. That wiring lives at the composition root and is
/// added by the integrator.
@MainActor
public protocol TerminalEngineRuntimeHosting: AnyObject {
    /// Reloads cmux's keyboard-shortcut settings file store (was
    /// `KeyboardShortcutSettings.settingsFileStore.reload()`).
    func reloadKeyboardShortcutSettingsFromFile()

    /// The cmux-managed terminal-settings Ghostty config layer, resolved
    /// app-side (was `TerminalManagedGhosttySettings.ghosttyConfigContents()`).
    func managedTerminalSettingsConfigContents() -> String?

    /// Whether `source` denotes a cmux theme reload (was
    /// `GhosttySurfaceConfigurationRefresh.isCmuxThemeReloadSource(_:)`).
    func isCmuxThemeReloadSource(_ source: String) -> Bool

    /// The terminal color-scheme preference readable against `backgroundColor`
    /// (was `cmuxReadableColorScheme(for:) == .light ? .light : .dark`).
    func terminalColorSchemePreference(
        forBackgroundColor backgroundColor: NSColor
    ) -> GhosttyConfig.ColorSchemePreference

    /// Applies the resolved terminal background to the key main window's chrome
    /// (was `applyBackgroundToKeyWindow()` driving `AppWindowChromeComposition`).
    func applyResolvedBackgroundToKeyWindow()

    /// Reports a fatal engine-initialization failure to the app's logging and
    /// crash-reporting sinks (was `sentryCaptureError(...)`).
    func reportInitializationFailure(_ message: String, data: [String: String])

    /// Submits a scroll-lag telemetry report when telemetry is enabled for the
    /// current launch (was the `ScrollLagProbe` report sink that checked
    /// `telemetrySettings.enabledForCurrentLaunch` then `SentrySDK.capture`).
    func submitScrollLagReport(_ report: ScrollLagReport)
}
