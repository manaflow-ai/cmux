import CmuxSettings
import Foundation

enum ShortcutHintDebugSettings {
    static let showModifierHoldHintsKey = SettingCatalog().shortcuts.showModifierHoldHints.userDefaultsKey
    static let defaultShowModifierHoldHints = SettingCatalog().shortcuts.showModifierHoldHints.defaultValue
    static let defaultSidebarHintX = 0.0
    static let defaultSidebarHintY = 0.0
    static let defaultTitlebarHintX = 0.0
    static let defaultTitlebarHintY = -5.0
    static let defaultPaneHintX = 0.0
    static let defaultPaneHintY = 0.0
    static let defaultRightSidebarCloseHintX = -10.0
    static let defaultRightSidebarCloseHintY = 3.3
    static let defaultRightSidebarFocusHintX = -1.6
    static let defaultRightSidebarFocusHintY = 1.7
    static let defaultAlwaysShowHints = false
    static let defaultShowHintsOnCommandHold = true
    static let defaultShowHintsOnControlHold = true

    static let offsetRange: ClosedRange<Double> = -20...20

    static func clamped(_ value: Double) -> Double {
        min(max(value, offsetRange.lowerBound), offsetRange.upperBound)
    }

    static func alwaysShowHints(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        defaultAlwaysShowHints || environment["CMUX_UI_TEST_SHORTCUT_HINTS_ALWAYS_SHOW"] == "1"
    }

    static func modifierHoldHintsEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: showModifierHoldHintsKey) != nil else {
            return defaultShowModifierHoldHints
        }
        return defaults.bool(forKey: showModifierHoldHintsKey)
    }

    static func showHintsOnCommandHoldEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaultShowHintsOnCommandHold && modifierHoldHintsEnabled(defaults: defaults)
    }

    static func showHintsOnControlHoldEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaultShowHintsOnControlHold && modifierHoldHintsEnabled(defaults: defaults)
    }
}
