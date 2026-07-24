import Foundation

@MainActor
extension DockSplitStore {
    /// Routes a panel attention request through the shared live-container
    /// registry. This is the Dock equivalent of Workspace's panel lookup and is
    /// intentionally container-agnostic: both workspace and global Docks
    /// register in `liveStores`.
    @discardableResult
    static func routeAttentionFlash(
        panelID: UUID,
        reason: WorkspaceAttentionFlashReason,
        requiresSplit: Bool = false,
        shouldFocus: Bool = false
    ) -> Bool {
        guard let dock = liveStores.first(where: { $0.containsPanel(panelID) }),
              let panel = dock.panels[panelID],
              panel.panelType == .terminal else {
            return false
        }
        if shouldFocus {
            dock.focusPanel(panelID)
        }
        if requiresSplit,
           dock.bonsplitController.allPaneIds.count <= 1,
           dock.panels.count <= 1 {
            return true
        }
        panel.triggerFlash(reason: reason)
        return true
    }

    /// Gives a Dock-owned terminal a Dock-owned pane-flash callback. A terminal
    /// moved out of a workspace can otherwise retain the workspace closure and
    /// send its flash into the old pane overlay.
    func installAttentionFlashRouting(for panel: any Panel) {
        guard let terminal = panel as? TerminalPanel else { return }
        terminal.onRequestWorkspacePaneFlash = { [weak self, weak terminal] reason in
            guard let self, let terminal,
                  let mountedTerminal = self.panels[terminal.id] as? TerminalPanel,
                  mountedTerminal === terminal else {
                return
            }
            mountedTerminal.hostedView.triggerFlash(
                style: GhosttySurfaceScrollView.flashStyle(for: reason)
            )
        }
    }
}
