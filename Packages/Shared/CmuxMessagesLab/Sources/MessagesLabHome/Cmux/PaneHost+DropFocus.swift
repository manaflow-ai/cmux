// cmux: after a drop or a pick, the person types at once (Lawrence
// 2026-10-19: "when i drop in an image or attachment to imessage, i expect
// to be focused in text input area"). Not a vendored file.
import AppKit

extension ChatController {
    /// A drop on the field: the host's intake takes the files, promised files
    /// and pictures, then the field takes the keyboard. (A drop on the rest of
    /// the pane goes to the host's view around it.)
    /// - Parameter pasteboard: The drag's pasteboard.
    /// - Returns: True when the intake took the drop.
    func takeDrop(_ pasteboard: NSPasteboard) -> Bool {
        guard intents?.takeDroppedAttachments(from: pasteboard) == true else { return false }
        focusComposeForTyping()
        return true
    }

    /// The field takes the keyboard with the caret at the end of the draft,
    /// then the window becomes key. A field that already has the keyboard
    /// keeps its caret (the person was typing there). The draft text does
    /// not change.
    ///
    /// The field first: the host's focus follows the first responder, and a
    /// window that becomes key with no click gives the keys back to the
    /// host's own focus target. Forward first, that target was still a
    /// browser page in another pane, whose page window took the keys, and
    /// the field stayed first responder of a window that was not key
    /// (Lawrence 2026-11-19: "i just put image here, and i had to click").
    func focusComposeForTyping() {
        guard !Self.noFocus, let window, let field = demo?.compose.textView.view else { return }
        if window.firstResponder !== field, window.makeFirstResponder(field) {
            field.setSelectedRange(NSRange(location: (field.string as NSString).length, length: 0))
        }
        if !window.isKeyWindow { bringWindowForward(window) }
    }
}

extension ChatController {
    /// Where an attachment enters the field's text: the caret's UTF-16 offset when the field
    /// shows the draft's text and holds the keyboard (nil: the end).
    func composeCaret() -> Int? {
        guard let demo, let store else { return nil }
        let tv = demo.compose.textView.view
        // Only a field that holds the keyboard has a caret the person placed.
        guard tv.string == store.state.ui.draft.text, tv.window?.firstResponder === tv else { return nil }
        let sel = tv.selectedRange()
        return sel.location == NSNotFound ? nil : sel.upperBound
    }
}
