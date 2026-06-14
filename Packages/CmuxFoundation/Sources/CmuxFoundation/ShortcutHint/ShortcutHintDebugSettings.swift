public import AppKit

/// Default offsets and feature flags for the keyboard shortcut-hint overlays
/// shown while a modifier is held.
public struct ShortcutHintDebugSettings {
    private let defaults: UserDefaults
    private let environment: [String: String]

    /// Creates a shortcut-hint settings reader.
    ///
    /// - Parameters:
    ///   - defaults: Defaults store containing shortcut-hint flags.
    ///   - environment: Process environment containing UI-test overrides.
    public init(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.defaults = defaults
        self.environment = environment
    }

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
        Self(environment: environment).alwaysShowHints()
    }

    /// Whether hints should always be shown for this reader.
    public func alwaysShowHints() -> Bool {
        Self.defaultAlwaysShowHints || environment["CMUX_UI_TEST_SHORTCUT_HINTS_ALWAYS_SHOW"] == "1"
    }

    /// Whether the user-facing modifier-hold hint toggle is enabled. Reads the
    /// raw value written by the `shortcuts.showModifierHoldHints` setting,
    /// falling back to ``defaultShowModifierHoldHints`` when unset.
    public static func modifierHoldHintsEnabled(defaults: UserDefaults = .standard) -> Bool {
        Self(defaults: defaults).modifierHoldHintsEnabled()
    }

    /// Whether the user-facing modifier-hold hint toggle is enabled for this reader.
    public func modifierHoldHintsEnabled() -> Bool {
        guard defaults.object(forKey: Self.showModifierHoldHintsKey) != nil else {
            return Self.defaultShowModifierHoldHints
        }
        return defaults.bool(forKey: Self.showModifierHoldHintsKey)
    }

    /// Whether command-hold hints are enabled. Gated by the user-facing
    /// modifier-hold hint toggle.
    public static func showHintsOnCommandHoldEnabled(defaults: UserDefaults = .standard) -> Bool {
        Self(defaults: defaults).showHintsOnCommandHoldEnabled()
    }

    /// Whether command-hold hints are enabled for this reader.
    public func showHintsOnCommandHoldEnabled() -> Bool {
        Self.defaultShowHintsOnCommandHold && modifierHoldHintsEnabled()
    }

    /// Whether control-hold hints are enabled. Gated by the user-facing
    /// modifier-hold hint toggle.
    public static func showHintsOnControlHoldEnabled(defaults: UserDefaults = .standard) -> Bool {
        Self(defaults: defaults).showHintsOnControlHoldEnabled()
    }

    /// Whether control-hold hints are enabled for this reader.
    public func showHintsOnControlHoldEnabled() -> Bool {
        Self.defaultShowHintsOnControlHold && modifierHoldHintsEnabled()
    }

}
