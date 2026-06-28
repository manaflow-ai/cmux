public import CmuxTerminalCore
public import GhosttyKit

/// The app-target seam ``TerminalAppearanceCoordinator`` calls back through for
/// the effects that must stay on the `GhosttyApp` god type: the live
/// `ghostty_app_t` color-scheme write, the configuration reload, the background
/// debug log, and the reload-reentrancy depth the coordinator does not own.
///
/// The `ghostty_app_t` handle itself never crosses this boundary. The app
/// conformer keeps the pointer private and exposes only `appearanceHasGhosttyApp`
/// (whether a handle exists) plus `appearanceApplyGhosttyRuntimeColorScheme`
/// (which performs `ghostty_app_set_color_scheme` against the private handle).
///
/// Isolation design: the conformer (`GhosttyApp`) is a non-isolated class whose
/// appearance methods run on the main thread by convention, so this protocol is
/// non-isolated and the coordinator holds the host weakly, mirroring the sibling
/// ``TerminalDefaultAppearanceState`` drain. No member suspends; every call is a
/// synchronous main-thread forward.
public protocol TerminalAppearanceHosting: AnyObject {
    /// Whether background appearance logging is enabled (gates every log line).
    var appearanceBackgroundLogEnabled: Bool { get }

    /// Emits one background debug log line.
    func appearanceLogBackground(_ message: String)

    /// The app-owned configuration-reload reentrancy depth, read by the
    /// reload-action reentrancy guard the coordinator does not own.
    var appearanceReloadConfigurationDepth: Int { get }

    /// Whether the app currently holds a live `ghostty_app_t` handle.
    var appearanceHasGhosttyApp: Bool { get }

    /// Applies the requested runtime color scheme to the live `ghostty_app_t`
    /// handle (no-op if the handle is gone). The handle stays app-side.
    func appearanceApplyGhosttyRuntimeColorScheme(_ runtimeColorScheme: ghostty_color_scheme_e)

    /// Reloads the ghostty configuration for the given color-scheme preference
    /// without re-reading settings from disk (the cold appearance-sync reload).
    func appearanceReloadConfiguration(
        source: String,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    )
}
