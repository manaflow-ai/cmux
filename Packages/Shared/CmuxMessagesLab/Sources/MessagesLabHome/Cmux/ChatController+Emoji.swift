// cmux: the emoji button beside the message box. Not a vendored file.
import AppKit

extension ChatController {
    /// Opens the system emoji picker for the message box.
    ///
    /// The picker attaches to the key window's current text input context,
    /// and AppKit switches that context to a new first responder only after
    /// the event that moved the keyboard has been handled. The button used to
    /// focus the field and ask for the picker in the same click: unless the
    /// field already held the keyboard, the picker opened for the old
    /// responder (the pane or the transcript), so nothing showed or a chosen
    /// emoji went nowhere. Now the field takes the keyboard (and its window
    /// becomes key), and the picker is asked one turn later, once the field's
    /// context is current.
    func showEmojiPicker() {
        guard !Self.noFocus else { return }
        let field = demo?.compose.textView.view
        let ready = field != nil && window?.isKeyWindow == true && window?.firstResponder === field
        focusComposeForTyping()
        if ready { openEmojiPalette(); return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let field = self.demo?.compose.textView.view, self.window?.firstResponder === field else { return }
            self.openEmojiPalette()
        }
    }
}
