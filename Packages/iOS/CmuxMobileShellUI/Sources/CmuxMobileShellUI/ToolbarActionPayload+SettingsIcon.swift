import CmuxMobileTerminalKit

extension ToolbarActionPayload {
    /// SF Symbol for a custom action's row in the shortcuts settings list,
    /// distinguishing a text snippet from a key-combo / macro so the list conveys
    /// what each custom button does.
    var settingsRowSystemImage: String {
        switch self {
        case .text: return "character.cursor.ibeam"
        case .keyCombo, .macro: return "command"
        }
    }
}
