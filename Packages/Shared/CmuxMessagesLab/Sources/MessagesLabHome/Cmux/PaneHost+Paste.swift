import AppKit

// cmux: Paste after a click on a bubble. The click moves the key focus to the transcript (as in
// Messages), and Command-V is a key equivalent, not a key down: AppKit tries the window's views
// (`performKeyEquivalent`) and then the main menu's Paste, which sends `paste:` to the first
// responder. The transcript took neither, so the round 4 capture pasted nothing. Both paths now
// reach the field: the transcript's `paste:` (the menu's Paste) gives the field the focus and
// pastes there, and the transcript's key equivalent takes Command-V while the key focus is in
// this pane's transcript or field, so the paste also works where no menu sees the key (a window
// that is not key, driven by the DEBUG socket's window events).

extension TranscriptDocumentView {
    /// The menu's Paste with the transcript focused: the field takes the focus and pastes (Home's
    /// attachment intake first, `FieldTextView.paste`).
    @objc func paste(_ sender: Any?) {
        controller?.pasteIntoField(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let c = controller, ChatController.isPaste(event), let window, event.window === window || event.window == nil,
              let field = c.demo?.compose.textView.view,
              window.firstResponder === self || window.firstResponder === field else { return super.performKeyEquivalent(with: event) }
        c.pasteIntoField(nil)
        return true
    }
}

extension ChatController {
    /// Command-V (no other modifier).
    static func isPaste(_ e: NSEvent) -> Bool {
        e.type == .keyDown && e.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command]
            && e.charactersIgnoringModifiers?.lowercased() == "v"
    }

    /// Gives the field the key focus and pastes there (the field's own Paste).
    func pasteIntoField(_ sender: Any?) {
        guard let field = demo?.compose.textView.view else { return }
        if window?.firstResponder !== field { window?.makeFirstResponder(field) }
        field.paste(sender)
    }
}
