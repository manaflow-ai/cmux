import AppKit
import Foundation

struct WorkspaceLayoutNumberedShortcutHint {
    let hasChord: Bool
    let modifierFlags: NSEvent.ModifierFlags
    let modifierDisplayString: String
}

enum WorkspaceLayoutShortcutHintSettings {
    static let paneHintXKey = "shortcutHintPaneTabXOffset"
    static let paneHintYKey = "shortcutHintPaneTabYOffset"
    static let alwaysShowHintsKey = "shortcutHintAlwaysShow"
    static let showHintsOnCommandHoldKey = "shortcutHintShowOnCommandHold"

    static let defaultPaneHintX = 0.0
    static let defaultPaneHintY = 0.0
    static let defaultAlwaysShowHints = false
    static let defaultShowHintsOnCommandHold = true

    static let offsetRange: ClosedRange<Double> = -20...20

    static var selectSurfaceByNumberShortcutProvider: () -> WorkspaceLayoutNumberedShortcutHint = {
        WorkspaceLayoutNumberedShortcutHint(
            hasChord: false,
            modifierFlags: [.control],
            modifierDisplayString: "⌃"
        )
    }

    static func clamped(_ value: Double) -> Double {
        min(max(value, offsetRange.lowerBound), offsetRange.upperBound)
    }

    static func showHintsOnCommandHoldEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: showHintsOnCommandHoldKey) != nil else {
            return defaultShowHintsOnCommandHold
        }
        return defaults.bool(forKey: showHintsOnCommandHoldKey)
    }
}
