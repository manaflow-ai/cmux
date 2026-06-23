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
        Color(hex: action.backgroundColorHex.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .white
    }

    static func localizedTitle(for action: TextBoxSubmitAction) -> String {
        switch action.id {
        case TextBoxSubmitAction.textEntryAction.id:
            return String(localized: "textbox.submitAction.textEntry", defaultValue: "Text Entry")
        case "claude":
            return String(localized: "textbox.submitAction.claude", defaultValue: "Claude")
        case "codex":
            return String(localized: "textbox.submitAction.codex", defaultValue: "Codex")
        case "opencode":
            return String(localized: "textbox.submitAction.opencode", defaultValue: "OpenCode")
        case "pi":
            return String(localized: "textbox.submitAction.pi", defaultValue: "Pi")
        default:
            return action.title
        }
    }
}
