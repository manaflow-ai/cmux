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
            state.workspaces[index].applyFocusSnapshot(event)
            workspacesByMac[macID] = state
            return
        }
        mutateForegroundWorkspaces { workspaces in
            guard let index = workspaces.firstIndex(where: {
                $0.rpcWorkspaceID.rawValue == event.workspaceID
            }) else { return }
            workspaces[index].applyFocusSnapshot(event)
        }
    }
}

private extension MobileWorkspacePreview {
    mutating func applyFocusSnapshot(_ event: MobileWorkspaceFocusEvent) {
        let paneID = event.focusedPaneID.map(MobilePanePreview.ID.init(rawValue:))
        let terminalID = event.selectedTerminalID.map(MobileTerminalPreview.ID.init(rawValue:))
        focusedPaneID = paneID
        selectedTerminalID = terminalID
        for index in panes.indices {
            panes[index].isFocused = panes[index].id == paneID
        }
        for index in terminals.indices {
            terminals[index].isFocused = terminals[index].id == terminalID
        }
    }
}
