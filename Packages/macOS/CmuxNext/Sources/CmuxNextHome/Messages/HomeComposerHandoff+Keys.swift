public import AppKit
public import CmuxNextPages

/// Up and Down from outside a Messages page (Lawrence 2026-10-19: "Up arrow ... handle unfocus as
/// well"; the native HomeHostView+PrimaryInputHistory): while the pane has the keyboard outside the
/// page (no responder after a pane-focus shortcut, the pane itself), a plain Up or Down focuses the
/// page's message box and steps its sent-message history. Inside the page the page does the same
/// itself (composerHandoff.ts `recallFromOutside`), so a field, a list or a text selection keeps its arrows.
extension HomeComposerHandoff {
    /// The box takes the keyboard and recalls an older (`older`) or newer sent message.
    public func recallHistory(older: Bool) async {
        _ = await call("home.messages.recallHistory", ["older": .bool(older)], within: Self.answerDeadline)
    }

    /// A plain Up (true) or Down (false) while `page`'s window has the keyboard outside it; nil for
    /// any other key, a chord, or a key inside the page (the page handles its own).
    public static func historyArrow(_ event: NSEvent, outside page: NSView) -> Bool? {
        guard event.type == .keyDown, event.keyCode == 126 || event.keyCode == 125, let window = page.window else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        guard flags.isEmpty else { return nil }
        if let view = window.firstResponder as? NSView, view === page || view.isDescendant(of: page) { return nil }
        return event.keyCode == 126
    }
}

extension HomeComposerHosting {
    /// `event`, a history arrow from outside `page` (``HomeComposerHandoff/historyArrow(_:outside:)``):
    /// the page takes the keyboard and its box steps the history.
    public func recallHistory(_ event: NSEvent, page: PageWebView) {
        guard let older = HomeComposerHandoff.historyArrow(event, outside: page) else { return }
        let handoff = composerHandoff
        page.focusPage()
        // task-owner: one page call; ends with its answer or the deadline
        // main-hop-allow: already on main (a key); the task only awaits the page's answer
        Task { @MainActor in await handoff.recallHistory(older: older) }
    }
}
