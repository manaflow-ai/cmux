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

    func forkAgentConversationContextMenuOpenSelection(
        forPanelId panelId: UUID
    ) -> (
        availability: WorkspaceForkAgentConversationAvailability,
        snapshot: SessionRestorableAgentSnapshot?
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
        snapshot: SessionRestorableAgentSnapshot?
    ) {
        guard panels[panelId] is TerminalPanel else { return (.notTerminalPanel, nil) }
        guard allowsAgentContinuation(forPanelId: panelId) else {
            return (.noAgentSnapshot, nil)
        }

        if let restoredSnapshot = restoredAgentSnapshotForContinuation(panelId: panelId) {
            switch ContentView.commandPaletteSnapshotForkAvailability(
                restoredSnapshot,
                isRemoteTerminal: isRemoteTerminalSurface(panelId)
            ) {
            case .supportedWithoutProbe:
                return (.available, restoredSnapshot)
            case .unsupported:
                return (.unsupported, nil)
            case .requiresProbe:
                break
            }
        }

        guard liveAgentIndex.prepareForkAvailabilityProbe(
            workspaceId: id,
            panelId: panelId
        ) else {
            return (.agentIndexRefreshing, nil)
        }
        guard let verifiedSnapshot = liveAgentIndex.snapshotForForkAvailability(
            workspaceId: id,
            panelId: panelId
        ) else {
            return (.noAgentSnapshot, nil)
        }
        if let observation = liveAgentIndex.index?.entry(workspaceId: id, panelId: panelId) {
            reconcileCompletedRestoredAgent(panelId: panelId, observation: observation)
        }
        guard allowsAgentContinuation(forPanelId: panelId) else {
            return (.noAgentSnapshot, nil)
        }

        switch ContentView.commandPaletteSnapshotForkAvailability(
            verifiedSnapshot,
            isRemoteTerminal: isRemoteTerminalSurface(panelId)
        ) {
        case .supportedWithoutProbe, .requiresProbe:
            return (.available, verifiedSnapshot)
        case .unsupported:
            return (.unsupported, nil)
        }
    }

    private func forkAgentConversationContextMenuCandidateSnapshot(
        forPanelId panelId: UUID
    ) -> SessionRestorableAgentSnapshot? {
        if let snapshot = restoredAgentSnapshotForContinuation(panelId: panelId) {
            return snapshot
        }
        guard let snapshot = SharedLiveAgentIndex.shared.snapshotForForkConversationCandidate(
            workspaceId: id,
            panelId: panelId
        ) else {
            return nil
        }
        if let observation = SharedLiveAgentIndex.shared.index?.entry(
            workspaceId: id,
            panelId: panelId
        ) {
            reconcileCompletedRestoredAgent(panelId: panelId, observation: observation)
        }
        return allowsAgentContinuation(forPanelId: panelId) ? snapshot : nil
    }
}
