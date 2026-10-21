import AppKit

/// Up and Down in a Home conversation (Lawrence 2026-10-19: "Up arrow ...
/// handle unfocus as well"): through the key dispatcher's one primary-input
/// path (`PrimaryInputTarget.routesToPrimaryInput`), a plain Up or Down while
/// Home has the keyboard outside its message box (no responder after a
/// pane-focus shortcut, the pane, the transcript, a header button) focuses the
/// box and steps its history. The box's own arrows recall through its own key
/// handling (first-line rule); other text inputs and a held transcript
/// selection keep theirs (the dispatcher delivers to them).
extension HomeHostView {
    /// Whether Home's message box claims `event`: printable and dead keys, and
    /// the history arrows from anywhere in Home that does not keep its arrows.
    func routesToPrimaryInput(_ event: NSEvent) -> Bool {
        if KeyRouter.historyArrow(event) != nil { return historyTakesArrowKeys(from: window?.firstResponder) }
        return KeyRouter.isPrintable(event) || KeyRouter.isDeadKey(event)
    }

    /// A history arrow steps the box's history (it focuses the box); any
    /// other key is typed into the box.
    func beginTyping(with event: NSEvent) {
        if let older = KeyRouter.historyArrow(event) {
            transcript.recallPrimaryInputHistory(older: older)
            return
        }
        guard let window else { return }
        if window.firstResponder !== focusTarget { guard window.makeFirstResponder(focusTarget) else { return } }
        focusTarget.keyDown(with: event)
    }

    /// Whether a plain Up or Down from `responder` belongs to the history:
    /// yes from outside this view; inside it, not from a text input or a
    /// transcript text selection.
    func historyTakesArrowKeys(from responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView, view === self || view.isDescendant(of: self) else { return true }
        return transcript.primaryInputHistoryTakesArrowKeys(from: responder)
    }
}
