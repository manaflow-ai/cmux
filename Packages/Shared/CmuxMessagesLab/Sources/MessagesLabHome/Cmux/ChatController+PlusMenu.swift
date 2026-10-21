// cmux: text the host's + menu puts in the message box (a clipboard row). Not a vendored file.
import AppKit

extension ChatController {
    /// The field takes the keyboard (its caret stays where the person left it; a field that did
    /// not hold the keyboard puts it at the end of the draft), then `text` goes in at the caret,
    /// replacing a selection, through the field's own typing path (`insertText`), so the draft,
    /// undo and the field's height follow as they do for typed text.
    /// - Parameter text: The text to insert; empty inserts nothing.
    func insertIntoCompose(_ text: String) {
        guard !text.isEmpty, let field = demo?.compose.textView.view else { return }
        focusComposeForTyping()
        field.insertText(text, replacementRange: field.selectedRange())
    }
}
