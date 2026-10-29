package import Foundation

/// TextBox composer strings (table TextBox.xcstrings).
package nonisolated struct TextBoxStrings {
    package nonisolated init() {}
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "TextBox", bundle: .module)
    }

    package static var placeholder: String { t("textbox.placeholder", "Prompt or command") }
    package static var textEntry: String { t("textbox.action.textEntry", "Text") }
    package static var cycleHelp: String { t("textbox.action.cycleHelp", "Submit action (Shift-Tab to change)") }
    package static var addFiles: String { t("textbox.addFiles.tooltip", "Add Files") }
    package static var addFilesPanelTitle: String { t("textbox.addFiles.panel.title", "Add Files") }
    package static var addFilesPanelPrompt: String { t("textbox.addFiles.panel.prompt", "Add") }
}
