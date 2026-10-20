import Foundation

struct TextBoxSubmitActionPresentation: Equatable {
    let action: TextBoxSubmitAction
    let isForcedTextEntry: Bool

    var label: String {
        if isForcedTextEntry {
            return String(localized: "textbox.submitAction.activeAgent", defaultValue: "Text Entry")
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
            return String(localized: "textbox.submitAction.activeAgent.tooltip", defaultValue: "This terminal uses Text Entry until command launch is available. Shift-Tab is disabled while Text Entry is forced.")
        }
        return String(
            format: String(localized: "textbox.submitAction.tooltip", defaultValue: "Submit with %@. Press Shift-Tab to change."),
            label
        )
    }

    static func localizedTitle(for action: TextBoxSubmitAction) -> String {
        let matchesBuiltInDefinition = TextBoxSubmitAction.selectableActions.first { $0.id == action.id } == action
        guard matchesBuiltInDefinition else {
            return action.title
        }
        switch action.id {
        case TextBoxSubmitAction.textEntryAction.id:
            return String(localized: "textbox.submitAction.textEntry", defaultValue: "Text Entry")
        case "claude":
            return String(localized: "textbox.submitAction.claude", defaultValue: "Claude Dangerous")
        case "codex":
            return String(localized: "textbox.submitAction.codex", defaultValue: "Codex --yolo")
        case "opencode":
            return String(localized: "textbox.submitAction.opencode", defaultValue: "OpenCode")
        case "pi":
            return String(localized: "textbox.submitAction.pi", defaultValue: "Pi")
        default:
            return action.title
        }
    }
}
