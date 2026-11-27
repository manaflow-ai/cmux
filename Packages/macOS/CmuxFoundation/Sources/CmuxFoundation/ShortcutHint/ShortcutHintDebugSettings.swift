public import AppKit

/// Default offsets and feature flags for the keyboard shortcut-hint overlays
/// shown while a modifier is held.
public struct ShortcutHintDebugSettings {
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

    /// Clamps a debug offset value into ``offsetRange``.
    public static func clamped(_ value: Double) -> Double {
        min(max(value, offsetRange.lowerBound), offsetRange.upperBound)
    }

    /// Whether hints should always be shown, honoring the UI-test override
    /// environment variable.
    public var alwaysShowHints: Bool {
        Self.defaultAlwaysShowHints || environment["CMUX_UI_TEST_SHORTCUT_HINTS_ALWAYS_SHOW"] == "1"
    }

    /// Whether the user-facing modifier-hold hint toggle is enabled.
    ///
    /// Reads the raw value written by the `shortcuts.showModifierHoldHints`
    /// setting, falling back to ``defaultShowModifierHoldHints`` when unset.
    public var modifierHoldHintsEnabled: Bool {
        guard defaults.object(forKey: Self.showModifierHoldHintsKey) != nil else {
            return Self.defaultShowModifierHoldHints
        }
        return defaults.bool(forKey: Self.showModifierHoldHintsKey)
    }

    /// Whether command-hold hints are enabled.
    public var showHintsOnCommandHoldEnabled: Bool {
        Self.defaultShowHintsOnCommandHold && modifierHoldHintsEnabled
    }

    /// Whether control-hold hints are enabled.
    public var showHintsOnControlHoldEnabled: Bool {
        Self.defaultShowHintsOnControlHold && modifierHoldHintsEnabled
    }
}
