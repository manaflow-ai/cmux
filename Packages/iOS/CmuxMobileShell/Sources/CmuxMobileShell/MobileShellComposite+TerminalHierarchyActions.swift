public import CmuxMobileShellModel

extension MobileShellComposite {
    /// Closes one stable terminal identity and selects the same index, otherwise
    /// the previous survivor, only after the authoritative refresh succeeds.
    @discardableResult
    public func closeTerminal(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID,
        confirmed: Bool,
        reservation: MobileTerminalReorderReservation
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        guard terminalReorderGate.owns(reservation) else {
            return .failure(.busy(hostDisplayName: workspaceHostDisplayName(for: workspaceID)))
        }
        defer {
            terminalReorderGate.finish(reservation)
        }
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }),
              workspace.actionCapabilities.supportsTerminalCloseActions,
              let terminal = workspace.terminals.first(where: { $0.id == terminalID }),
              terminal.canClose,
              reservation.workspaceID == workspaceID else {
            return .failure(.rejected(hostDisplayName: workspaceHostDisplayName(for: workspaceID)))
        }
        let paneIDs = terminal.paneID.map { workspace.terminals(in: $0).map(\.id) } ?? []
        let fallback = MobileTerminalCloseFallback(
            closedTerminalID: terminalID,
            selectedTerminalID: selectedTerminalID,
            orderedTerminalIDs: paneIDs.isEmpty ? workspace.terminals.map(\.id) : paneIDs
        )
        let selectionRevision = userTerminalSelectionRevision
        var params = workspaceMutationParams(id: workspaceID)
        params["surface_id"] = terminalID.rawValue
        params["confirmed"] = confirmed
        let result = await sendWorkspaceMutation(
            method: "terminal.close",
            params: params,
            id: workspaceID,
            actionName: "terminal_close"
        )
        guard case .success = result,
              selectedWorkspaceID == workspaceID,
              let refreshedWorkspace = workspaces.first(where: { $0.id == workspaceID }) else {
            return result
        }
        selectedTerminalID = fallback.resolvedSelection(
            currentSelection: userTerminalSelectionRevision == selectionRevision ? nil : selectedTerminalID,
            availableTerminalIDs: Set(refreshedWorkspace.terminals.map(\.id))
        ) ?? refreshedWorkspace.selectedTerminalID ?? refreshedWorkspace.terminals.first?.id
        suppressTerminalAutoFocusOnNextAttach(for: selectedTerminalID)
        return result
    }

    /// Persists an in-pane terminal reorder and rejects stale or cross-boundary
    /// intents before sending any mutation.
    @discardableResult
    public func reorderTerminal(
        workspaceID: MobileWorkspacePreview.ID,
        intent: MobileTerminalReorderIntent,
        reservation: MobileTerminalReorderReservation
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        guard terminalReorderGate.owns(reservation) else {
            return .failure(.busy(hostDisplayName: workspaceHostDisplayName(for: workspaceID)))
        }
        defer {
            terminalReorderGate.finish(reservation)
        }
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }),
              workspace.actionCapabilities.supportsTerminalReorderActions,
              workspace.hasCoherentTerminalReorderMembership,
              let pane = workspace.resolvedPanes.first(where: { $0.id == intent.paneID }),
              pane.terminalIDs.contains(intent.terminalID) else {
            return .failure(.rejected(hostDisplayName: workspaceHostDisplayName(for: workspaceID)))
        }
        guard reservation.workspaceID == workspaceID,
              reservation.paneID == intent.paneID else {
            return .failure(.busy(hostDisplayName: workspaceHostDisplayName(for: workspaceID)))
        }
        var params = workspaceMutationParams(id: workspaceID)
        params["surface_id"] = intent.terminalID.rawValue
        params["pane_id"] = intent.paneID.rawValue
        params["index"] = intent.targetIndex
        return await sendWorkspaceMutation(
            method: "terminal.reorder",
            params: params,
            id: workspaceID,
            actionName: "terminal_reorder"
        )
    }
}
