internal import CmuxMobileRPC
internal import CmuxMobileShellModel

extension MobileShellComposite {
    /// Applies a focus-only event without fetching or decoding the full list.
    func applyWorkspaceFocusEvent(_ event: MobileWorkspaceFocusEvent, macID: String?) {
        if let macID {
            guard var state = workspacesByMac[macID],
                  let index = state.workspaces.firstIndex(where: {
                      $0.rpcWorkspaceID.rawValue == event.workspaceID
                  }) else { return }
            applyFocusSnapshot(event, to: &state.workspaces[index])
            workspacesByMac[macID] = state
            return
        }
        mutateForegroundWorkspaces { workspaces in
            guard let index = workspaces.firstIndex(where: {
                $0.rpcWorkspaceID.rawValue == event.workspaceID
            }) else { return }
            applyFocusSnapshot(event, to: &workspaces[index])
        }
    }
}

private func applyFocusSnapshot(
    _ event: MobileWorkspaceFocusEvent,
    to workspace: inout MobileWorkspacePreview
) {
    let paneID = event.focusedPaneID.map(MobilePanePreview.ID.init(rawValue:))
    let terminalID = event.selectedTerminalID.map(MobileTerminalPreview.ID.init(rawValue:))
    workspace.focusedPaneID = paneID
    workspace.selectedTerminalID = terminalID
    for index in workspace.panes.indices {
        workspace.panes[index].isFocused = workspace.panes[index].id == paneID
    }
    for index in workspace.terminals.indices {
        workspace.terminals[index].isFocused = workspace.terminals[index].id == terminalID
    }
}
