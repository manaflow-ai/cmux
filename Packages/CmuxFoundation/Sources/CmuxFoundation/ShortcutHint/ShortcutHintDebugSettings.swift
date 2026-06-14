public import AppKit

/// Default offsets and feature flags for the keyboard shortcut-hint overlays
/// shown while a modifier is held. Pure value namespace reading from an
/// injected `UserDefaults` / process environment; holds no mutable state.
// lint:allow namespace-type — pure stateless policy/value namespace lifted verbatim from ContentView; no natural receiver, modernization deferred.
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

    /// Raw `UserDefaults` key backing the user-facing
    /// `shortcuts.showModifierHoldHints` toggle. `CmuxFoundation` is a leaf
    /// module and cannot import `CmuxSettings`, so the key is duplicated here;
    /// `ShortcutHintDebugSettingsBindingTests` asserts it stays in sync with
    /// `SettingCatalog().shortcuts.showModifierHoldHints`.
    public static let showModifierHoldHintsKey = "showModifierHoldHints"

    /// Default applied for ``showModifierHoldHintsKey`` when the user has not
    /// set it; mirrors the catalog default for `shortcuts.showModifierHoldHints`.
    public static let defaultShowModifierHoldHints = true

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

    /// Whether the user-facing modifier-hold hint toggle is enabled. Reads the
    /// raw value written by the `shortcuts.showModifierHoldHints` setting,
    /// falling back to ``defaultShowModifierHoldHints`` when unset.
    public static func modifierHoldHintsEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: showModifierHoldHintsKey) != nil else {
            return defaultShowModifierHoldHints
        }
        return defaults.bool(forKey: showModifierHoldHintsKey)
    }

    /// Whether command-hold hints are enabled. Gated by the user-facing
    /// modifier-hold hint toggle.
    public static func showHintsOnCommandHoldEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaultShowHintsOnCommandHold && modifierHoldHintsEnabled(defaults: defaults)
    }

    /// Whether control-hold hints are enabled. Gated by the user-facing
    /// modifier-hold hint toggle.
    public static func showHintsOnControlHoldEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaultShowHintsOnControlHold && modifierHoldHintsEnabled(defaults: defaults)
    }

}
