internal import CmuxMobileRPC
public import CmuxMobileShellModel
internal import CmuxMobileSupport
internal import Foundation

enum MobileTerminalCreationMutationClaim {
    case blocked
    case unreserved
    case reserved(MobileTerminalReorderReservation)
}

extension MobileShellComposite {
    func createRemoteTerminal(
        in explicitWorkspaceID: MobileWorkspacePreview.ID? = nil,
        paneID: MobilePanePreview.ID? = nil
    ) async {
        guard let client = remoteClient,
              let rowWorkspaceID = explicitWorkspaceID ?? selectedWorkspace?.id else { return }
        let requestedWorkspaceID = remoteWorkspaceID(for: rowWorkspaceID)
        let existingTerminalIDs = Set(
            workspaces.first(where: { $0.id == rowWorkspaceID })?.terminals.map(\.id) ?? []
        )
        let generation = connectionGeneration
        let focusRevision = workspaceFocusRevisionSnapshot()
        let responseMutationEpoch = foregroundWorkspaceListMutationEpoch
        do {
            var params: [String: Any] = ["workspace_id": requestedWorkspaceID.rawValue]
            if let paneID {
                params["pane_id"] = paneID.rawValue
            }
            let resultData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "terminal.create",
                    params: params
                )
            )
            let response = try MobileSyncWorkspaceListResponse.decode(resultData)
            guard isCurrentRemoteOperation(client: client, generation: generation),
                  !Task.isCancelled else { return }
            advanceForegroundWorkspaceListMutationEpoch()
            applyRemoteWorkspaceList(
                response,
                mergeExistingWorkspaces: true,
                listStartedAtFocusRevision: focusRevision
            )
            markForegroundWorkspaceListApplied(through: responseMutationEpoch)
            if selectedWorkspaceID == rowWorkspaceID,
               let createdTerminalID = resolvedRemoteTerminalCreationSelection(
                   responseCreatedTerminalID: response.createdTerminalID,
                   workspaceID: rowWorkspaceID,
                   existingTerminalIDs: existingTerminalIDs,
                   paneID: paneID
               ) {
                selectTerminal(createdTerminalID)
                suppressTerminalAutoFocusOnNextAttach(for: createdTerminalID)
            }
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return }
            markMacConnectionUnavailableIfNeeded(after: error)
            applyOperationalError(error)
        }
    }

    /// Resolves the terminal identity the phone should select after a remote
    /// create. Some hosts acknowledge with the transient bonsplit create ID
    /// while the returned workspace already exposes the durable panel ID. Trust
    /// the acknowledgement only when it exists in the returned hierarchy;
    /// otherwise select the one new identity in the requested pane. Titles are
    /// deliberately ignored because duplicate terminal titles are normal.
    func resolvedRemoteTerminalCreationSelection(
        responseCreatedTerminalID: String?,
        workspaceID: MobileWorkspacePreview.ID,
        existingTerminalIDs: Set<MobileTerminalPreview.ID>,
        paneID: MobilePanePreview.ID?
    ) -> MobileTerminalPreview.ID? {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return nil }
        if let responseCreatedTerminalID {
            let responseID = MobileTerminalPreview.ID(rawValue: responseCreatedTerminalID)
            if workspace.terminals.contains(where: { $0.id == responseID }) {
                return responseID
            }
        }

        let addedTerminals = workspace.terminals.filter { !existingTerminalIDs.contains($0.id) }
        if let paneID {
            let addedInPane = addedTerminals.filter { $0.paneID == paneID }
            if addedInPane.count == 1 { return addedInPane[0].id }
            if addedInPane.count > 1 { return nil }
        }
        return addedTerminals.count == 1 ? addedTerminals[0].id : nil
    }

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
