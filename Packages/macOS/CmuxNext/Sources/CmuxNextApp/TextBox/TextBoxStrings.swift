import Foundation

/// TextBox composer strings (table TextBox.xcstrings).
nonisolated enum TextBoxStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "TextBox", bundle: .module)
    }

    static var placeholder: String { t("textbox.placeholder", "Prompt or command") }
    static var textEntry: String { t("textbox.action.textEntry", "Text") }
    static var cycleHelp: String { t("textbox.action.cycleHelp", "Submit action (Shift-Tab to change)") }
    static var addFiles: String { t("textbox.addFiles.tooltip", "Add Files") }
    static var addFilesPanelTitle: String { t("textbox.addFiles.panel.title", "Add Files") }
    static var addFilesPanelPrompt: String { t("textbox.addFiles.panel.prompt", "Add") }
}
