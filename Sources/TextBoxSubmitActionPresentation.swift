import SwiftUI

struct TextBoxSubmitActionPresentation: Equatable {
    let action: TextBoxSubmitAction
    let isForcedTextEntry: Bool

    var label: String {
        if isForcedTextEntry {
            return String(localized: "textbox.submitAction.activeAgent", defaultValue: "Text Entry for Active Agent")
        }
        return Self.localizedTitle(for: action)
    }

    var accessibilityLabel: String {
        String(
            format: String(localized: "textbox.submitAction.accessibility", defaultValue: "Submit with %@"),
            label
        )
    }

    var helpText: String {
        if isForcedTextEntry {
            return String(localized: "textbox.submitAction.activeAgent.tooltip", defaultValue: "Active agent sessions use Text Entry. Shift-Tab changes the default for new sessions.")
        }
        return String(
            format: String(localized: "textbox.submitAction.tooltip", defaultValue: "Submit with %@. Press Shift-Tab to change."),
            label
        )
    }

    var backgroundColor: Color {
        Self.color(hex: action.backgroundColorHex) ?? .white
    }

    static func localizedTitle(for action: TextBoxSubmitAction) -> String {
        switch action.id {
        case TextBoxSubmitAction.textEntryAction.id:
            return String(localized: "textbox.submitAction.textEntry", defaultValue: "Text Entry")
        case "claude":
            return String(localized: "textbox.submitAction.claude", defaultValue: "Claude Dangerous")
        case "codex":
            return String(localized: "textbox.submitAction.codex", defaultValue: "Codex Yolo")
        case "opencode":
            return String(localized: "textbox.submitAction.opencode", defaultValue: "OpenCode")
        case "pi":
            return String(localized: "textbox.submitAction.pi", defaultValue: "Pi")
        default:
            return action.title
        }
    }

    static func color(hex rawHex: String) -> Color? {
        var hex = rawHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        guard (hex.count == 6 || hex.count == 8),
              let value = UInt64(hex, radix: 16) else {
            return nil
        }

        let red: UInt64
        let green: UInt64
        let blue: UInt64
        let alpha: UInt64
        if hex.count == 8 {
            red = (value >> 24) & 0xFF
            green = (value >> 16) & 0xFF
            blue = (value >> 8) & 0xFF
            alpha = value & 0xFF
        } else {
            red = (value >> 16) & 0xFF
            green = (value >> 8) & 0xFF
            blue = value & 0xFF
            alpha = 0xFF
        }

        return Color(
            red: Double(red) / 255.0,
            green: Double(green) / 255.0,
            blue: Double(blue) / 255.0,
            opacity: Double(alpha) / 255.0
        )
    }
}
