import AppKit

extension GhosttyNSView {
    @IBAction func copyCurrentSurfaceLink(_ sender: Any?) {
        guard let terminalSurface,
              let workspace = terminalSurface.owningWorkspace(),
              let link = WorkspaceSurfaceIdentifierClipboardText.makeSurfaceLink(
                workspace: workspace,
                panelId: terminalSurface.id
              ) else {
            NSSound.beep()
            return
        }
        WorkspaceSurfaceIdentifierClipboardText.copy(link)
    }
}
