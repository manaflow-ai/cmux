public import AppKit

/// Default offsets and feature flags for the keyboard shortcut-hint overlays
/// shown while a modifier is held. Pure value namespace reading from an
/// injected `UserDefaults` / process environment; holds no mutable state.
public enum ShortcutHintDebugSettings {
    public static let defaultSidebarHintX = 0.0
    public static let defaultSidebarHintY = 0.0
    public static let defaultTitlebarHintX = 0.0
    public static let defaultTitlebarHintY = -5.0
    public static let defaultPaneHintX = 0.0
    public static let defaultPaneHintY = 0.0
    public static let defaultRightSidebarCloseHintX = -10.0
    public static let defaultRightSidebarCloseHintY = 3.3
    public static let defaultRightSidebarFocusHintX = -1.6
    public static let defaultRightSidebarFocusHintY = 1.7
    public static let defaultAlwaysShowHints = false
    public static let defaultShowHintsOnCommandHold = true
    public static let defaultShowHintsOnControlHold = true

    /// Allowed range (in points) for a debug hint position offset.
    public static let offsetRange: ClosedRange<Double> = -20...20

    /// Clamps a debug offset value into `offsetRange`.
    public static func clamped(_ value: Double) -> Double {
        min(max(value, offsetRange.lowerBound), offsetRange.upperBound)
    }

    /// Whether hints should always be shown, honoring the UI-test override
    /// environment variable.
    public static func alwaysShowHints(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        defaultAlwaysShowHints || environment["CMUX_UI_TEST_SHORTCUT_HINTS_ALWAYS_SHOW"] == "1"
    }

    /// Whether command-hold hints are enabled.
    public static func showHintsOnCommandHoldEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaultShowHintsOnCommandHold
    }

    /// Whether control-hold hints are enabled.
    public static func showHintsOnControlHoldEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaultShowHintsOnControlHold
    }

}
