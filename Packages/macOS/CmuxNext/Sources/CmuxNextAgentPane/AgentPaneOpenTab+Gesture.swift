import Foundation

extension AgentPaneOpenTab {
    /// Whether the open runs a command line: a terminal with `run` and text (an empty field opens a
    /// bare terminal, a browser tab runs nothing), or a terminal that types (`run: false`) a control
    /// key. Typed text reaches the pty as raw keys, so a newline, a carriage return or Ctrl-O in it
    /// runs the line as `run` would (cx-hnpxh).
    nonisolated var runsCommand: Bool {
        guard kind == .terminal else { return false }
        return run ? !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : Self.typesControlKey(text)
    }

    /// Whether typing `text` at a prompt presses a key that acts by itself: a C0 control (newline,
    /// Return, Ctrl-O, Escape, ...) or a C1 control. DEL stays a plain key: it is the type-ahead's
    /// erase (`NewTabTypeAhead.delta`). The New Tab field types none; the shell card's Open in
    /// Terminal of a multi-line command is a click, so it has the gesture.
    nonisolated static func typesControlKey(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || (0x80...0x9F).contains($0.value) }
    }

    /// The page's `tab.open` in `model`'s pane: the App opens the tab when the pane is the New Tab
    /// page or a chat in a tab. A run needs the person's fresh gesture in the pane, used once, as
    /// `shell.run` does (cx-hnpxh): page script cannot make one, so a chat's rendered output cannot
    /// run a line. The New Tab page's Return and the cards' Log In / Update clicks are such gestures.
    @MainActor func open(in model: AgentPaneModel) -> [String: Any] {
        guard model.newTab != nil || model.allowsTabConversion, let onOpenTab = model.onOpenTab else {
            return AgentPaneModel.unsupported("tab.open")
        }
        if runsCommand, !model.transport.gestures.consume() { return AgentPaneModel.transportFailure(.gestureRequired) }
        onOpenTab(self)
        return AgentPaneReply.success()
    }

    /// The page's `tab.typeAhead` in `model`'s pane: what it typed so far, for the terminal that
    /// replaces it. The terminal gets it as raw keys too, so a control key in it needs the
    /// person's gesture like a run (cx-hnpxh); printable text and DEL pass.
    @MainActor static func typeAhead(_ text: String, in model: AgentPaneModel) -> [String: Any] {
        guard model.newTab != nil || model.allowsTabConversion, let onTypeAhead = model.onTypeAhead else {
            return AgentPaneModel.unsupported("tab.typeAhead")
        }
        if typesControlKey(text), !model.transport.gestures.consume() { return AgentPaneModel.transportFailure(.gestureRequired) }
        onTypeAhead(text)
        return AgentPaneReply.success()
    }
}
