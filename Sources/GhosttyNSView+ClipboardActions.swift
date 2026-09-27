import AppKit
import CmuxSettings

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
        if sendAgentImagePasteKeyIfEnabled() {
            return
        }
        if performBindingAction("paste_from_clipboard") {
            terminalSurface?.didAcceptExplicitInput()
        }
    }

    /// With `terminal.agentImagePasteSendsCtrlV` on, sends Ctrl+V instead of
    /// pasting when Claude Code or Codex runs in this local pane and the
    /// clipboard holds only an image, so the agent attaches the image itself.
    /// Returns false, leaving the regular paste to run, in every other case,
    /// including when the key could not be delivered.
    private func sendAgentImagePasteKeyIfEnabled() -> Bool {
        let isEnabled = TerminalCatalogSection()
            .agentImagePasteSendsCtrlV.value(in: .standard)
        guard isEnabled,
              let terminalSurface,
              let workspace = terminalSurface.owningWorkspace(),
              let panel = workspace.panels[terminalSurface.id] as? TerminalPanel,
              !panel.isAgentHibernated else {
            return false
        }
        let shouldSend = TerminalAgentImagePasteRouting.shouldSendAgentPasteKey(
            isEnabled: isEnabled,
            agentContext: {
                WorkspaceContentView.terminalAgentContext(panel: panel, workspace: workspace)
            },
            pasteboardTypes: { NSPasteboard.general.types ?? [] },
            resolveTarget: {
                terminalSurface.resolvedImageTransferTarget(mode: .paste, in: workspace)
            }
        )
        guard shouldSend else { return false }
        let delivered = panel.sendNamedKey(TerminalAgentImagePasteRouting.agentPasteKeyName)
#if DEBUG
        cmuxDebugLog(
            "terminal.agentImagePaste.ctrlV surface=\(terminalSurface.id.uuidString.prefix(5)) " +
            "delivered=\(delivered ? 1 : 0)"
        )
#endif
        return delivered
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
