public import Foundation

/// The light/dark preference that drives terminal theme selection.
///
/// This is the terminal-domain home of what was `GhosttyConfig.ColorSchemePreference`.
/// It is the value libghostty theme resolution keys off of, distinct from the
/// app's broader appearance mode (which also carries `system`/`auto`). cmux
/// resolves the app appearance mode down to this two-case preference before
/// loading terminal colors.
public enum TerminalColorSchemePreference: Hashable, Sendable {
    case light
    case dark

    /// The persisted user-defaults key holding the app's appearance mode.
    /// Frozen wire-format key; reading it here keeps terminal theme resolution
    /// from reaching up into the app's appearance settings type.
    public static let appearanceModeDefaultsKey = "appearanceMode"

    /// Resolves the terminal color-scheme preference the way cmux's appearance
    /// mode drives Ghostty split-theme selection: an explicit `light`/`dark`
    /// mode wins; `system`, `auto`, unset, or unrecognized modes fall back to
    /// the system interface style.
    ///
    /// This mirrors the legacy `AppearanceSettings.terminalColorSchemePreference`
    /// resolution exactly (`AppearanceMode.mode(for:)` collapses `auto` to
    /// `system` and unknown values to the `system` default, after which only
    /// `.light`/`.dark` short-circuit).
    public static func resolve(
        appearanceModeRawValue: String?,
        systemAppearance: TerminalSystemAppearance?,
        defaults: UserDefaults = .standard
    ) -> TerminalColorSchemePreference {
        switch appearanceModeRawValue {
        case "light":
            return .light
        case "dark":
            return .dark
        default:
            return (systemAppearance ?? .current(defaults: defaults)).prefersDark ? .dark : .light
        }
    }

    /// Reads the persisted appearance mode from the given defaults and resolves
    /// the terminal preference. The zero-config entry point used at config-load
    /// time.
    public static func current(
        defaults: UserDefaults = .standard,
        systemAppearance: TerminalSystemAppearance? = nil
    ) -> TerminalColorSchemePreference {
        resolve(
            appearanceModeRawValue: defaults.string(forKey: appearanceModeDefaultsKey),
            systemAppearance: systemAppearance,
            defaults: defaults
        )
    }
}
