import CmuxMobileShellModel

/// Resolves the terminal opened by the grid's Done action.
struct WorkspaceSurfaceGridSelection {
    let workspace: MobileWorkspacePreview
    let selectedTerminalID: MobileTerminalPreview.ID?

    func terminalIDToOpen() -> MobileTerminalPreview.ID? {
        if let selectedTerminalID,
           workspace.terminals.contains(where: { $0.id == selectedTerminalID }) {
            return selectedTerminalID
        }
        return workspace.terminals.first?.id
    }
}
