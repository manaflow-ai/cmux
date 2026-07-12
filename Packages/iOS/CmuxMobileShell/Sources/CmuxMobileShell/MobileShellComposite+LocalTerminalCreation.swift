public import CmuxMobileShellModel
internal import CmuxMobileSupport

extension MobileShellComposite {
    /// Resolves a real host pane for a remote create. Compatibility panes are
    /// presentation-only and must never be sent to the host as stable IDs.
    func remoteTerminalCreationPaneID(
        in workspace: MobileWorkspacePreview?,
        explicitPaneID: MobilePanePreview.ID?
    ) -> MobilePanePreview.ID? {
        guard let workspace,
              workspace.actionCapabilities.supportsTerminalCreateInPane else { return nil }
        if let explicitPaneID { return explicitPaneID }
        guard !workspace.panes.isEmpty else { return nil }
        return workspace.terminalCreationPaneID
    }

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
            resolvedPaneID = workspace.panes.isEmpty ? nil : workspace.terminalCreationPaneID
        }
        var terminalIndex = workspace.terminals.count + 1
        let existingTerminalIDs = Set(workspace.terminals.map(\.id))
        var terminalID = MobileTerminalPreview.ID(
            rawValue: "\(workspace.id.rawValue)-terminal-\(terminalIndex)"
        )
        while existingTerminalIDs.contains(terminalID) {
            terminalIndex += 1
            terminalID = MobileTerminalPreview.ID(
                rawValue: "\(workspace.id.rawValue)-terminal-\(terminalIndex)"
            )
        }
        let terminal = MobileTerminalPreview(
            id: terminalID,
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
        selectTerminal(terminal.id)
        suppressTerminalAutoFocusOnNextAttach(for: terminal.id)
    }
}
