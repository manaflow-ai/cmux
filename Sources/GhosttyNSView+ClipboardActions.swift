import AppKit

extension GhosttyNSView {
    func recordDirectAgentHibernationTerminalInput() {
        guard let terminalSurface else { return }
        GhosttyApp.terminalSurfaceRuntimeDependencies
            .hibernationRecorder.recordTerminalInput(
                workspaceId: terminalSurface.tabId,
                panelId: terminalSurface.id
            )
    }

    @IBAction func paste(_ sender: Any?) {
        guard prepareSurfaceForPaste(reason: "paste.missingSurface") else {
            return
        }
        recordDirectAgentHibernationTerminalInput()
        if performBindingAction("paste_from_clipboard") {
            terminalSurface?.didAcceptExplicitInput()
        }
    }

    /// Pastes clipboard text as plain text, stripping any rich formatting.
    @IBAction func pasteAsPlainText(_ sender: Any?) {
        guard prepareSurfaceForPaste(
            reason: "pasteAsPlainText.missingSurface"
        ) else {
            return
        }
        recordDirectAgentHibernationTerminalInput()
        if performBindingAction("paste_from_clipboard") {
            terminalSurface?.didAcceptExplicitInput()
        }
    }
}
