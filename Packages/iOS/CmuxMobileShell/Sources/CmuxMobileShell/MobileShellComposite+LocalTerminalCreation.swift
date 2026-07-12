public import CmuxMobileShellModel
internal import CmuxMobileSupport

enum MobileTerminalCreationMutationClaim {
    case blocked
    case unreserved
    case reserved(MobileTerminalReorderReservation)
}

extension MobileShellComposite {
    /// Resolves a real host pane for a remote create. Compatibility panes are
    /// presentation-only and must never be sent to the host as stable IDs.
    func remoteTerminalCreationPaneID(
        in workspace: MobileWorkspacePreview?,
        explicitPaneID: MobilePanePreview.ID?
    ) -> MobilePanePreview.ID? {
        guard let workspace,
              workspace.actionCapabilities.supportsTerminalCreateInPane else { return nil }
        return liveTerminalCreationPaneID(in: workspace, explicitPaneID: explicitPaneID)
    }

    /// Resolves pane selection only against the current host hierarchy. Focus
    /// events can temporarily outlive their pane during a concurrent refresh.
    private func liveTerminalCreationPaneID(
        in workspace: MobileWorkspacePreview,
        explicitPaneID: MobilePanePreview.ID?
    ) -> MobilePanePreview.ID? {
        let livePaneIDs = Set(workspace.panes.map(\.id))
        if let explicitPaneID, livePaneIDs.contains(explicitPaneID) {
            return explicitPaneID
        }
        if let focusedPaneID = workspace.focusedPaneID, livePaneIDs.contains(focusedPaneID) {
            return focusedPaneID
        }
        return workspace.panes.first(where: \.isFocused)?.id ?? workspace.panes.first?.id
    }

    /// Enrolls modern terminal creation in the same hierarchy mutation owner as
    /// close and reorder, so full-list responses cannot apply out of order.
    func claimTerminalCreationMutation(
        in workspace: MobileWorkspacePreview?,
        paneID: MobilePanePreview.ID?
    ) -> MobileTerminalCreationMutationClaim {
        guard let workspace,
              workspace.actionCapabilities.supportsTerminalCloseActions
                || workspace.actionCapabilities.supportsTerminalReorderActions else {
            return .unreserved
        }
        guard let paneID,
              let reservation = terminalReorderGate.reserve(
                  workspaceID: workspace.id,
                  paneID: paneID
              ) else {
            return .blocked
        }
        return .reserved(reservation)
    }

    func finishTerminalCreationMutation(_ claim: MobileTerminalCreationMutationClaim) {
        guard case let .reserved(reservation) = claim else { return }
        terminalReorderGate.finish(reservation)
    }

    /// Creates and selects a preview/local terminal in one exact pane.
    func createLocalTerminal(
        in workspaceID: MobileWorkspacePreview.ID?,
        paneID: MobilePanePreview.ID?
    ) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        selectedWorkspaceID = workspaceID
        let resolvedPaneID = liveTerminalCreationPaneID(in: workspace, explicitPaneID: paneID)
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
