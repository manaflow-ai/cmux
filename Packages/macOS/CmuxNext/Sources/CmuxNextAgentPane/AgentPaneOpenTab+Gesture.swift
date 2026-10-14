import Foundation

extension AgentPaneOpenTab {
    /// Whether the open runs a command line: a terminal with `run` and text (an empty field opens a
    /// bare terminal, `run: false` only types at the prompt, a browser tab runs nothing).
    nonisolated var runsCommand: Bool {
        kind == .terminal && run && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
}
