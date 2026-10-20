// cmux: after a drop or a pick, the person types at once (Lawrence
// 2026-10-19: "when i drop in an image or attachment to imessage, i expect
// to be focused in text input area"). Not a vendored file.
import AppKit

extension ChatController {
    /// A drop on the pane or on the field: the host's intake takes the files
    /// and pictures, then the field takes the keyboard.
    /// - Parameter pasteboard: The drag's pasteboard.
    /// - Returns: True when the intake took the drop.
    func takeDrop(_ pasteboard: NSPasteboard) -> Bool {
        guard intents?.takeAttachments(from: pasteboard) == true else { return false }
        focusComposeForTyping()
        return true
    }

    /// The field takes the keyboard with the caret at the end of the draft,
    /// and the window becomes key. A field that already has the keyboard
    /// keeps its caret (the person was typing there). The draft text does
    /// not change.
    func focusComposeForTyping() {
        guard !Self.noFocus, let window, let field = demo?.compose.textView.view else { return }
        if !window.isKeyWindow { bringWindowForward(window) }
        guard window.firstResponder !== field else { return }
        guard window.makeFirstResponder(field) else { return }
        field.setSelectedRange(NSRange(location: (field.string as NSString).length, length: 0))
    }
}
