// cmux: where the keyboard goes when Home gets focus, and Cmd+V anywhere in
// the pane (Lawrence 2026-10-18: "When I focus on the home thing it needs to
// just focus on the right place", "When I do Command-V anywhere in the home
// thing ... it should automatically paste properly ... into the text input
// area and focus it"). Not a vendored file.
import AppKit

extension ChatController {
    /// Whether focusing the pane should move the keyboard from `responder`
    /// to the compose field.
    ///
    /// The keyboard stays on any text view or text field (the compose field
    /// itself, the thread header's field, a find field's editor) and on the
    /// transcript while the person makes or holds a text selection there
    /// (Copy). Everything else (no responder, the window, the pane itself,
    /// a header button) gives the field the keyboard.
    func composeShouldTakeKeyboard(from responder: NSResponder?) -> Bool {
        if responder is NSText || responder is NSTextField { return false }
        if let doc = responder as? TranscriptDocumentView, doc === host.scrollView.document,
           selection.dragging || !selection.isEmpty {
            return false
        }
        return true
    }

    /// Whether Cmd+V from the pane has something for the compose field: text,
    /// or files and pictures the host's intake takes (the same rule as a drop).
    func canPasteIntoCompose() -> Bool {
        guard let field = demo?.compose.textView.view else { return false }
        let pb = field.pasteboard
        if field.acceptsPastePasteboard(pb) { return true }
        return pasteboardHasText(pb)
    }

    /// Cmd+V from anywhere in the pane that is not a text field: the compose
    /// field takes the keyboard and the paste, as if it had been focused.
    /// The field's own `paste(_:)` runs, so files and pictures go through the
    /// host's intake exactly as a paste in the field (and a drop) does.
    func pasteIntoCompose(_ sender: Any?) {
        guard let field = demo?.compose.textView.view else { return }
        if let window, window.firstResponder !== field { window.makeFirstResponder(field) }
        field.paste(sender)
    }
}

/// Cmd+V reaches the pane when its first responder has no `paste(_:)` (the
/// transcript while it holds a selection, the pane, a header button): the
/// responder chain brings it here, and the compose field takes it.
extension HostView: NSMenuItemValidation {
    @objc func paste(_ sender: Any?) { controller?.pasteIntoCompose(sender) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(paste(_:)) else { return true }
        return controller?.canPasteIntoCompose() ?? false
    }
}
