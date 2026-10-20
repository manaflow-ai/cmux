import Foundation
import Observation

/// One terminal's TextBox: its draft, whether it shows, and the submit action Return uses.
@MainActor @Observable
final class TextBoxModel {
    /// The draft. The text view writes it on every edit; the view shows what others write.
    var text = ""
    var isVisible = false
    let catalog: [TextBoxSubmitAction]
    private(set) var actionIndex = 0

    init(catalog: [TextBoxSubmitAction] = TextBoxSubmitAction.catalog) {
        self.catalog = catalog.isEmpty ? [.textEntry] : catalog
    }

    var action: TextBoxSubmitAction { catalog[actionIndex] }

    /// The next submit action, wrapping to the first.
    func cycle() {
        actionIndex = (actionIndex + 1) % catalog.count
    }

    /// Appends `paths`, shell-quoted and space-separated, after a space when the draft does not end in one.
    func insert(paths: [String]) {
        guard !paths.isEmpty else { return }
        let joined = paths.map(TextBoxSubmitAction.quoted).joined(separator: " ")
        let separator = text.isEmpty || text.last?.isWhitespace == true ? "" : " "
        text += separator + joined
    }

    /// What a submit sends (the action's input for the draft), clearing the draft; nil for a blank draft.
    func takeInput() -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let input = action.input(for: text)
        text = ""
        return input
    }
}
