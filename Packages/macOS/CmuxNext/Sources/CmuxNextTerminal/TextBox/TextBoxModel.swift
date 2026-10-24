package import Foundation
package import Observation

/// One terminal's TextBox: its draft, whether it shows, and the submit action Return uses.
@MainActor @Observable
package final class TextBoxModel {
    /// The draft. The text view writes it on every edit; the view shows what others write.
    package var text = ""
    package var isVisible = false
    package let catalog: [TextBoxSubmitAction]
    package private(set) var actionIndex = 0

    package init(catalog: [TextBoxSubmitAction] = TextBoxSubmitAction.catalog) {
        self.catalog = catalog.isEmpty ? [.textEntry] : catalog
    }

    package var action: TextBoxSubmitAction { catalog[actionIndex] }

    /// The next submit action, wrapping to the first.
    package func cycle() {
        actionIndex = (actionIndex + 1) % catalog.count
    }

    /// Appends `paths`, shell-quoted and space-separated, after a space when the draft does not end in one.
    package func insert(paths: [String]) {
        guard !paths.isEmpty else { return }
        let joined = paths.map(TextBoxSubmitAction.quoted).joined(separator: " ")
        let separator = text.isEmpty || text.last?.isWhitespace == true ? "" : " "
        text += separator + joined
    }

    /// What a submit sends (the action's input for the draft), clearing the draft; nil for a blank draft.
    package func takeInput() -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let input = action.input(for: text)
        text = ""
        return input
    }
}
