import AppKit

/// Home's list and transcript (a Home tab, the docked Home's Messages view,
/// classic Home) have one primary input: the shown conversation's message
/// box. A pane focus lands there from anywhere but the conversation list
/// (its arrow keys move the selection) and a visible text input (the list's
/// search field, a field of the transcript); a printable key typed while the
/// list or the page itself has the keyboard goes to the box (Lawrence
/// 2026-10-19: "If I type randomly, or if I focus using Command + Up/Down
/// Arrow key to focus the pane and start typing, it doesn't actually work").
extension TopHomePageView: PrimaryInputTarget {
    var primaryInputView: NSView? { host?.primaryInputView }

    /// The shown conversation's keys (Home's one key path: `HomeHostView`).
    func routesToPrimaryInput(_ event: NSEvent) -> Bool {
        guard let host else { return false }
        // The conversation list keeps its arrow keys (they move the selection).
        if KeyRouter.historyArrow(event) != nil, let view = window?.firstResponder as? NSView, view.isDescendant(of: list) {
            return false
        }
        return host.routesToPrimaryInput(event)
    }

    func beginTyping(with event: NSEvent) { host?.beginTyping(with: event) }

    func primaryInputShouldTakeKeyboard(from responder: NSResponder?) -> Bool {
        guard let host else { return false }
        guard let view = responder as? NSView, view === self || view.isDescendant(of: self) else { return true }
        if view === host || view.isDescendant(of: host) { return host.primaryInputShouldTakeKeyboard(from: responder) }
        if view.ownsTypedText { return false }
        // The conversation list itself (not a hidden or read-only field in it) keeps its arrow keys.
        return !(view.isDescendant(of: list) && !(view is NSText || view is NSTextField))
    }
}
