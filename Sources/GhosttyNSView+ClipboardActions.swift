import AppKit
import GhosttyKit

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
        if let terminalSurface, terminalSurface.isExternallyManaged {
            guard let pasteboard = GhosttyApp.terminalPasteboard.pasteboard(
                for: GHOSTTY_CLIPBOARD_STANDARD
            ), let text = GhosttyApp.terminalPasteboard.stringContents(from: pasteboard) else {
                return
            }
            _ = terminalSurface.sendText(text)
            terminalSurface.noteClipboardReadCompleted()
            return
        }
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
        if let terminalSurface, terminalSurface.isExternallyManaged {
            guard let text = NSPasteboard.general.string(forType: .string) else { return }
            _ = terminalSurface.sendText(text)
            terminalSurface.noteClipboardReadCompleted()
            return
        }
        if performBindingAction("paste_from_clipboard") {
            terminalSurface?.didAcceptExplicitInput()
        }
    }
}
