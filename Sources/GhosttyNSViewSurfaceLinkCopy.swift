import AppKit

extension GhosttyNSView {
    @IBAction func copyCurrentSurfaceLink(_ sender: Any?) {
        guard let terminalSurface,
              let workspace = terminalSurface.owningWorkspace(),
              let panelId = workspace.panelId(forSurfaceId: terminalSurface.id),
              let link = WorkspaceSurfaceIdentifierClipboardText.makeSurfaceLink(
                workspace: workspace,
                panelId: panelId
              ) else {
            NSSound.beep()
            return
        }
        WorkspaceSurfaceIdentifierClipboardText.copy(link)
    }
}
