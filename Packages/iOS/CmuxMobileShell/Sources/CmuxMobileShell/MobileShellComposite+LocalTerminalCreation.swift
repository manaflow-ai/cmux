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
    /// Lower-level entrypoint retained for focused mutation-fence tests. It
    /// resolves the exact row owner before entering the async implementation.
    @discardableResult
    func createRemoteTerminal(
        in explicitWorkspaceID: MobileWorkspacePreview.ID? = nil,
        paneID: MobilePanePreview.ID? = nil
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        guard let rowWorkspaceID = explicitWorkspaceID ?? selectedWorkspace?.id else {
            return .failure(.notConnected(hostDisplayName: connectedHostName))
        }
        let target = workspaceMutationTarget(for: rowWorkspaceID)
        let hostDisplayName = workspaceMutationHostDisplayName(
            target: target,
            fallback: workspaceHostDisplayName(for: rowWorkspaceID)
        )
        return await createRemoteTerminal(
            in: rowWorkspaceID,
            remoteWorkspaceID: remoteWorkspaceID(for: rowWorkspaceID),
            paneID: paneID,
            target: target,
            hostDisplayName: hostDisplayName
        )
    }

    @discardableResult
    func createRemoteTerminal(
        in rowWorkspaceID: MobileWorkspacePreview.ID,
        remoteWorkspaceID requestedWorkspaceID: MobileWorkspacePreview.ID,
        paneID: MobilePanePreview.ID? = nil,
        target: WorkspaceMutationTarget,
        hostDisplayName: String?
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        // The row's owning connection is captured by the synchronous action
        // entrypoint. Never re-resolve through `remoteClient` after suspension:
        // aggregated Macs can expose the same raw workspace UUID.
        guard let client = target.client else {
            return .failure(.notConnected(hostDisplayName: hostDisplayName))
        }
        let existingTerminalIDs = Set(
            workspaces.first(where: { $0.id == rowWorkspaceID })?.terminals.map(\.id) ?? []
        )
        let generation = connectionGeneration
        let focusRevision = workspaceFocusRevisionSnapshot()
        let responseMutationEpoch = foregroundWorkspaceListMutationEpoch
        let responseListRevision = foregroundWorkspaceListAppliedRevision
        let createSelectionRevision = claimForegroundCreateSelection()
        let secondarySubscription = target.macDeviceID.flatMap { secondaryMacSubscriptions[$0] }
        let secondaryRefreshStartedGeneration = secondarySubscription?.refreshStartedGeneration
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
            let responseOutcome: RemoteCreateResponseOutcome
            if target.isForeground {
                responseOutcome = await applyOrReconcileRemoteCreateResponse(
                    response,
                    startedAt: responseMutationEpoch,
                    listRevision: responseListRevision,
                    focusRevision: focusRevision,
                    client: client,
                    generation: generation
                )
            } else {
                guard isCurrentTerminalCreateTarget(
                    target,
                    client: client,
                    generation: generation
                ), !Task.isCancelled else { return .success(()) }
                if let macDeviceID = target.macDeviceID,
                   let secondarySubscription,
                   let secondaryRefreshStartedGeneration,
                   applySecondaryCreateResponseIfCurrent(
                       response,
                       macID: macDeviceID,
                       subscription: secondarySubscription,
                       refreshStartedGeneration: secondaryRefreshStartedGeneration,
                       listStartedAtFocusRevision: focusRevision
                   ) {
                    responseOutcome = .appliedScopedResponse
                } else {
                    let reconciled = await refreshAfterWorkspaceMutation(target)
                    guard isCurrentTerminalCreateTarget(
                        target,
                        client: client,
                        generation: generation
                    ), !Task.isCancelled else { return .success(()) }
                    responseOutcome = reconciled
                        ? .reconciledAuthoritativeList
                        : .reconciliationRequired
                }
            }
            switch responseOutcome {
            case .invalidated:
                return .success(())
            case .reconciliationRequired:
                terminalReorderGate.requireRefresh(workspaceID: rowWorkspaceID)
                return .failure(.appliedNeedsRefresh(hostDisplayName: hostDisplayName))
            case .appliedScopedResponse, .reconciledAuthoritativeList:
                break
            }
            selectResolvedRemoteTerminalCreation(
                responseCreatedTerminalID: response.createdTerminalID,
                workspaceID: rowWorkspaceID,
                existingTerminalIDs: existingTerminalIDs,
                paneID: paneID,
                selectionRevision: createSelectionRevision
            )
            return .success(())
        } catch {
            guard isCurrentTerminalCreateTarget(target, client: client, generation: generation),
                  !Task.isCancelled else { return .success(()) }
            guard !invalidateTerminalCreateTargetForAuthorizationFailure(
                error,
                target: target,
                client: client
            ) else {
                return .failure(.authorizationFailed(hostDisplayName: hostDisplayName))
            }
            if target.isForeground {
                markMacConnectionUnavailableIfNeeded(after: error)
            }
            let disposition = workspaceMutationErrorDisposition(error)
            switch disposition {
            case .immediateRejection:
                break
            case .definiteDivergence, .ambiguous:
                let reconciled = await refreshAfterWorkspaceMutation(target)
                guard isCurrentTerminalCreateTarget(target, client: client, generation: generation),
                      !Task.isCancelled else { return .success(()) }
                if !reconciled {
                    terminalReorderGate.requireRefresh(workspaceID: rowWorkspaceID)
                    if disposition == .ambiguous {
                        if target.isForeground {
                            applyOperationalError(error)
                        }
                        return .failure(unreconciledWorkspaceMutationFailure(
                            error,
                            hostDisplayName: hostDisplayName
                        ))
                    }
                } else if disposition == .ambiguous {
                    // The response was lost, so the refreshed hierarchy cannot
                    // reliably attribute any one new terminal to this request.
                    // Keep the user's selection and clear the transient
                    // availability state now that an authoritative read worked.
                    if target.isForeground {
                        markMacConnectionHealthy()
                    }
                    return .failure(reconciledWorkspaceMutationFailure(
                        error,
                        hostDisplayName: hostDisplayName
                    ))
                }
            }
            if target.isForeground {
                applyOperationalError(error)
            }
            return .failure(workspaceMutationFailure(
                error,
                hostDisplayName: hostDisplayName
            ))
        }
    }

    /// Revalidates the exact owner/client captured by the action entrypoint.
    /// Foreground operations also retain the connection generation; secondary
    /// operations retain their per-Mac subscription identity through its client.
    private func isCurrentTerminalCreateTarget(
        _ target: WorkspaceMutationTarget,
        client: MobileCoreRPCClient,
        generation: UUID
    ) -> Bool {
        if target.isForeground {
            return target.client === remoteClient
                && isCurrentRemoteOperation(client: client, generation: generation)
        }
        guard let macDeviceID = target.macDeviceID else { return false }
        return secondaryMacSubscriptions[macDeviceID]?.client === client
    }

    /// Authorization failure invalidates only the connection that rejected the
    /// request. A secondary-Mac failure must never tear down foreground state.
    private func invalidateTerminalCreateTargetForAuthorizationFailure(
        _ error: any Error,
        target: WorkspaceMutationTarget,
        client: MobileCoreRPCClient
    ) -> Bool {
        guard Self.shouldDisconnectForAuthorizationFailure(error) else { return false }
        if target.isForeground {
            return disconnectForAuthorizationFailureIfNeeded(error)
        }
        guard let macDeviceID = target.macDeviceID,
              let subscription = secondaryMacSubscriptions[macDeviceID],
              subscription.client === client else { return true }
        subscription.cancel()
        secondaryMacSubscriptions[macDeviceID] = nil
        markSecondaryMacUnavailable(macDeviceID)
        return true
    }

    /// Selects one uniquely identified create result while the request still
    /// owns selection. Ambiguous transport failures pass no response ID and use
    /// the authoritative post-mutation hierarchy to identify the new terminal.
    private func selectResolvedRemoteTerminalCreation(
        responseCreatedTerminalID: String?,
        workspaceID: MobileWorkspacePreview.ID,
        existingTerminalIDs: Set<MobileTerminalPreview.ID>,
        paneID: MobilePanePreview.ID?,
        selectionRevision: UInt64
    ) {
        guard ownsForegroundCreateSelection(selectionRevision),
              selectedWorkspaceID == workspaceID,
              let createdTerminalID = resolvedRemoteTerminalCreationSelection(
                  responseCreatedTerminalID: responseCreatedTerminalID,
                  workspaceID: workspaceID,
                  existingTerminalIDs: existingTerminalIDs,
                  paneID: paneID
              ) else { return }
        selectTerminal(createdTerminalID)
        suppressTerminalAutoFocusOnNextAttach(for: createdTerminalID)
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
            return addedInPane.count == 1 ? addedInPane[0].id : nil
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

    /// Turns a blocked New Terminal action into the direct recovery path for
    /// that workspace. The action intentionally refreshes without creating:
    /// the preceding uncertain request may already have succeeded on the Mac.
    func recoverTerminalHierarchyForCreateIfRequired(
        in workspaceID: MobileWorkspacePreview.ID,
        target: WorkspaceMutationTarget,
        hostDisplayName: String?,
        completion: @escaping @MainActor (Result<Void, MobileWorkspaceMutationFailure>) -> Void
    ) -> Bool {
        guard terminalReorderGate.requiresRefresh(workspaceID: workspaceID) else {
            return false
        }
        let gate = terminalReorderGate
        let recoveryFailure = MobileWorkspaceMutationFailure.appliedNeedsRefresh(
            hostDisplayName: hostDisplayName
        )
        guard !terminalCreationRequestOwner.isActive else {
            completion(.failure(.busy(hostDisplayName: hostDisplayName)))
            return true
        }
        guard gate.beginRecovery(workspaceID: workspaceID) else {
            completion(.failure(.busy(hostDisplayName: hostDisplayName)))
            return true
        }
        let started = terminalCreationRequestOwner.startIfIdle(
            claim: .unreserved,
            gate: gate,
            cancellationOutcome: .failure(recoveryFailure),
            completion: { result in
                let succeeded: Bool
                if case .success = result {
                    succeeded = true
                } else {
                    succeeded = false
                }
                gate.finishRecovery(workspaceID: workspaceID, succeeded: succeeded)
                completion(result)
            }
        ) { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return .failure(recoveryFailure) }
            return await self.refreshAfterWorkspaceMutation(target)
                ? .success(())
                : .failure(recoveryFailure)
        }
        if !started {
            gate.finishRecovery(workspaceID: workspaceID, succeeded: false)
            completion(.failure(.busy(hostDisplayName: hostDisplayName)))
        }
        return true
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
