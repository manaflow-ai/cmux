// cmux: text the host's + menu puts in the message box (a clipboard row). Not a vendored file.
import AppKit

extension ChatController {
    /// The field takes the keyboard (its caret stays where the person left it; a field that did
    /// not hold the keyboard puts it at the end of the draft), then `text` goes in at the caret,
    /// replacing a selection, as Paste and Match Style puts it: the exact text (no smart quotes,
    /// dashes or autocorrect, which typing would apply), its own undo step, and `didChangeText`,
    /// so the draft and the field's height follow.
    /// - Parameter text: The text to insert; empty inserts nothing.
    func insertIntoCompose(_ text: String) {
        guard !text.isEmpty, let field = demo?.compose.textView.view, field.isEditable else { return }
        focusComposeForTyping()
        let range = field.selectedRange()
        guard field.shouldChangeText(in: range, replacementString: text), let storage = field.textStorage else { return }
        field.breakUndoCoalescing()
        storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: field.typingAttributes))
        field.setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        field.didChangeText()
        field.breakUndoCoalescing()
    }
}
