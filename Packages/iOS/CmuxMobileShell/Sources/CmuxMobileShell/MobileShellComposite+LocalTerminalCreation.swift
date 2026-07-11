public import CmuxMobileShellModel
internal import CmuxMobileSupport

extension MobileShellComposite {
    /// Creates and selects a preview/local terminal in one exact pane.
    func createLocalTerminal(
        in workspaceID: MobileWorkspacePreview.ID?,
        paneID: MobilePanePreview.ID?
    ) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        selectedWorkspaceID = workspaceID
        let resolvedPaneID: MobilePanePreview.ID?
        if let paneID {
            resolvedPaneID = workspace.panes.contains(where: { $0.id == paneID })
                ? paneID
                : workspace.panes.first(where: \.isFocused)?.id ?? workspace.panes.first?.id
        } else {
            resolvedPaneID = nil
        }
        let terminalIndex = workspace.terminals.count + 1
        let terminal = MobileTerminalPreview(
            id: .init(rawValue: "\(workspace.id.rawValue)-terminal-\(terminalIndex)"),
            name: L10n.terminalName(index: terminalIndex),
            paneID: resolvedPaneID
        )
        mutateForegroundWorkspaces { list in
            guard let workspaceIndex = list.firstIndex(where: { $0.id == workspaceID }) else { return }
            list[workspaceIndex].terminals.append(terminal)
            if let resolvedPaneID,
               let paneIndex = list[workspaceIndex].panes.firstIndex(where: { $0.id == resolvedPaneID }) {
                list[workspaceIndex].panes[paneIndex].terminalIDs.append(terminal.id)
            }
        }
        selectedTerminalID = terminal.id
        suppressTerminalAutoFocusOnNextAttach(for: terminal.id)
    }
}
