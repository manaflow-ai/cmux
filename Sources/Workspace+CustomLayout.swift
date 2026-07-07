import CmuxWorkspaces
import Foundation

// MARK: - cmux.json custom layout

extension Workspace {
    /// Applies a package-owned cmux.json `layout` block to this freshly created
    /// workspace. The setup command, when present, is prepended to the first
    /// terminal surface command before the package layout coordinator walks the
    /// resolved tree.
    func applyCustomLayout(
        _ layout: CmuxWorkspaces.CmuxLayoutNode,
        baseCwd: String,
        setupCommand: String? = nil
    ) {
        layoutCoordinator.applyCustomLayout(
            layout.workspaceCustomLayoutNode(prependingSetupCommand: setupCommand),
            baseCwd: baseCwd
        )
    }

    /// Sends a config-defined workspace `setup` command to the first terminal
    /// panel. Used by workspace actions/commands that define no custom layout.
    func sendConfigSetupCommand(_ command: String) {
        let firstTerminal: TerminalPanel? = focusedTerminalPanel ?? {
            for paneId in bonsplitController.allPaneIds {
                for tab in bonsplitController.tabs(inPane: paneId) {
                    if let panelId = panelIdFromSurfaceId(tab.id),
                       let terminal = terminalPanel(for: panelId) {
                        return terminal
                    }
                }
            }
            return nil
        }()
        guard let firstTerminal else { return }
        pendingTerminalInput.sendInputWhenReady(command + "\n", toPanelId: firstTerminal.id)
    }
}
