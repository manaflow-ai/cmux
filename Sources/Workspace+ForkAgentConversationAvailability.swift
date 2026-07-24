import Foundation

extension Workspace {
    func forkAgentConversationContextMenuAvailability(
        forPanelId panelId: UUID
    ) -> WorkspaceForkAgentConversationAvailability {
        guard panels[panelId] is TerminalPanel else { return .notTerminalPanel }
        guard let snapshot = forkAgentConversationContextMenuCandidateSnapshot(forPanelId: panelId) else {
            return .noAgentSnapshot
        }
        switch ContentView.commandPaletteSnapshotForkAvailability(
            snapshot,
            isRemoteTerminal: isRemoteTerminalSurface(panelId)
        ) {
        case .supportedWithoutProbe:
            return .available
        case .requiresProbe:
            return .requiresProbe
        case .unsupported:
            return .unsupported
        }
    }

    func forkAgentConversationContextMenuOpenAvailability(
        forPanelId panelId: UUID
    ) -> WorkspaceForkAgentConversationAvailability {
        forkAgentConversationContextMenuOpenAvailability(
            forPanelId: panelId,
            liveAgentIndex: .shared
        )
    }

    func forkAgentConversationContextMenuOpenAvailability(
        forPanelId panelId: UUID,
        liveAgentIndex: SharedLiveAgentIndex
    ) -> WorkspaceForkAgentConversationAvailability {
        forkAgentConversationContextMenuOpenSelection(
            forPanelId: panelId,
            liveAgentIndex: liveAgentIndex
        ).availability
    }

    func forkAgentConversationContextMenuPresentationAvailability(
        forPanelId panelId: UUID
    ) -> WorkspaceForkAgentConversationAvailability {
        forkAgentConversationContextMenuPresentationAvailability(
            forPanelId: panelId,
            liveAgentIndex: .shared
        )
    }

    func forkAgentConversationContextMenuPresentationAvailability(
        forPanelId panelId: UUID,
        liveAgentIndex: SharedLiveAgentIndex
    ) -> WorkspaceForkAgentConversationAvailability {
        let candidateAvailability = forkAgentConversationContextMenuAvailability(forPanelId: panelId)
        guard candidateAvailability == .available
            || candidateAvailability == .requiresProbe
            || candidateAvailability == .noAgentSnapshot else {
            return candidateAvailability
        }
        return forkAgentConversationContextMenuOpenAvailability(
            forPanelId: panelId,
            liveAgentIndex: liveAgentIndex
        )
    }

    func forkAgentConversationContextMenuOpenSelection(
        forPanelId panelId: UUID
    ) -> (
        availability: WorkspaceForkAgentConversationAvailability,
        snapshot: SessionRestorableAgentSnapshot?,
        validationFallbackSnapshot: SessionRestorableAgentSnapshot?
    ) {
        forkAgentConversationContextMenuOpenSelection(
            forPanelId: panelId,
            liveAgentIndex: .shared
        )
    }

    func forkAgentConversationContextMenuOpenSelection(
        forPanelId panelId: UUID,
        liveAgentIndex: SharedLiveAgentIndex
    ) -> (
        availability: WorkspaceForkAgentConversationAvailability,
        snapshot: SessionRestorableAgentSnapshot?,
        validationFallbackSnapshot: SessionRestorableAgentSnapshot?
    ) {
        guard panels[panelId] is TerminalPanel else { return (.notTerminalPanel, nil, nil) }

        let isRemoteContext = isRemoteTerminalSurface(panelId)
        if !allowsAgentContinuation(forPanelId: panelId) {
            if let observation = liveAgentIndex.index?.entry(workspaceId: id, panelId: panelId) {
                reconcileCompletedRestoredAgent(panelId: panelId, observation: observation)
            }
            if !allowsAgentContinuation(forPanelId: panelId) {
                guard liveAgentIndex.prepareForkAvailabilityProbe(
                    workspaceId: id,
                    panelId: panelId,
                    isRemoteContext: isRemoteContext
                ) else {
                    return (.agentIndexRefreshing, nil, nil)
                }
                if let observation = liveAgentIndex.index?.entry(workspaceId: id, panelId: panelId) {
                    reconcileCompletedRestoredAgent(panelId: panelId, observation: observation)
                }
            }
            guard allowsAgentContinuation(forPanelId: panelId) else {
                return (.noAgentSnapshot, nil, nil)
            }
        }
        let restoredSnapshot = restoredAgentSnapshotForContinuation(panelId: panelId)
        let liveAvailabilitySnapshot = liveAgentIndex.snapshotForForkAvailability(
            workspaceId: id,
            panelId: panelId,
            isRemoteContext: isRemoteContext
        )
        let liveCandidateSnapshot = liveAgentIndex.snapshotForForkConversationCandidate(
            workspaceId: id,
            panelId: panelId
        )
        if liveAvailabilitySnapshot == nil, liveCandidateSnapshot != nil {
            if liveAgentIndex.forkSupportProbeRejected(
                workspaceId: id,
                panelId: panelId,
                isRemoteContext: isRemoteContext
            ) {
                return (.unsupported, nil, nil)
            }
            guard liveAgentIndex.prepareForkAvailabilityProbe(
                workspaceId: id,
                panelId: panelId,
                isRemoteContext: isRemoteContext
            ) else {
                return (.agentIndexRefreshing, nil, nil)
            }
            return (.agentIndexRefreshing, nil, nil)
        }
        if let snapshotSource = ContentView.commandPaletteForkAvailabilitySnapshotSource(
            liveIndexSnapshot: liveAvailabilitySnapshot,
            fallbackSnapshot: restoredSnapshot,
            isRemoteTerminal: isRemoteContext
        ) {
            switch ContentView.commandPaletteSnapshotForkAvailability(
                snapshotSource.snapshot,
                isRemoteTerminal: isRemoteContext
            ) {
            case .supportedWithoutProbe:
                return (.available, snapshotSource.snapshot, nil)
            case .unsupported:
                return (.unsupported, nil, nil)
            case .requiresProbe:
                guard liveAgentIndex.prepareForkAvailabilityProbe(
                    workspaceId: id,
                    panelId: panelId,
                    isRemoteContext: isRemoteContext,
                    fallbackSnapshot: snapshotSource.validationFallbackSnapshot
                ) else {
                    return (.agentIndexRefreshing, nil, nil)
                }
                if liveAgentIndex.forkSupportProbeAccepted(
                    workspaceId: id,
                    panelId: panelId,
                    isRemoteContext: isRemoteContext,
                    fallbackSnapshot: snapshotSource.validationFallbackSnapshot
                ) {
                    return (
                        .available,
                        snapshotSource.snapshot,
                        snapshotSource.validationFallbackSnapshot
                    )
                }
                if liveAgentIndex.forkSupportProbeRejected(
                    workspaceId: id,
                    panelId: panelId,
                    isRemoteContext: isRemoteContext,
                    fallbackSnapshot: snapshotSource.validationFallbackSnapshot
                ) {
                    return (.unsupported, nil, nil)
                }
                return (.agentIndexRefreshing, nil, nil)
            }
        }

        guard liveAgentIndex.prepareForkAvailabilityProbe(
            workspaceId: id,
            panelId: panelId,
            isRemoteContext: isRemoteTerminalSurface(panelId)
        ) else {
            return (.agentIndexRefreshing, nil, nil)
        }
        guard let verifiedSnapshot = liveAgentIndex.snapshotForForkAvailability(
            workspaceId: id,
            panelId: panelId,
            isRemoteContext: isRemoteTerminalSurface(panelId)
        ) else {
            if liveAgentIndex.forkSupportProbeRejected(
                workspaceId: id,
                panelId: panelId,
                isRemoteContext: isRemoteTerminalSurface(panelId)
            ) {
                return (.unsupported, nil, nil)
            }
            return (.noAgentSnapshot, nil, nil)
        }
        if let observation = liveAgentIndex.index?.entry(workspaceId: id, panelId: panelId) {
            reconcileCompletedRestoredAgent(panelId: panelId, observation: observation)
        }
        guard allowsAgentContinuation(forPanelId: panelId) else {
            return (.noAgentSnapshot, nil, nil)
        }

        switch ContentView.commandPaletteSnapshotForkAvailability(
            verifiedSnapshot,
            isRemoteTerminal: isRemoteTerminalSurface(panelId)
        ) {
        case .supportedWithoutProbe, .requiresProbe:
            return (.available, verifiedSnapshot, nil)
        case .unsupported:
            return (.unsupported, nil, nil)
        }
    }

    private func forkAgentConversationContextMenuCandidateSnapshot(
        forPanelId panelId: UUID
    ) -> SessionRestorableAgentSnapshot? {
        guard allowsAgentContinuation(forPanelId: panelId) else { return nil }
        if let snapshot = SharedLiveAgentIndex.shared.snapshotForForkConversationCandidate(
            workspaceId: id,
            panelId: panelId
        ) {
            if let observation = SharedLiveAgentIndex.shared.index?.entry(
                workspaceId: id,
                panelId: panelId
            ) {
                reconcileCompletedRestoredAgent(panelId: panelId, observation: observation)
            }
            return snapshot
        }
        if let snapshot = restoredAgentSnapshotForContinuation(panelId: panelId) {
            return snapshot
        }
        if let observation = SharedLiveAgentIndex.shared.index?.entry(workspaceId: id, panelId: panelId) {
            reconcileCompletedRestoredAgent(panelId: panelId, observation: observation)
        }
        return nil
    }
}
