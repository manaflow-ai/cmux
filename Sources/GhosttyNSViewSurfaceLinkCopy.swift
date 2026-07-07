import AppKit

extension GhosttyNSView {
    @IBAction func copyCurrentSurfaceLink(_ sender: Any?) {
        guard let terminalSurface,
              let workspace = terminalSurface.owningWorkspace(),
              let panel = workspace.panels[terminalSurface.id] else {
            NSSound.beep()
            return
        }
        WorkspaceSurfaceIdentifierClipboardText.copy(
            WorkspaceSurfaceIdentifierClipboardText.makeSurfaceLink(
                workspaceId: workspace.stableId,
                surfaceId: panel.stableSurfaceId
            )
        )
    }
}
