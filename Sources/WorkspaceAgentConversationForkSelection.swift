import Foundation

struct WorkspaceAgentConversationForkSelection {
    let snapshot: SessionRestorableAgentSnapshot
    let validationFallbackSnapshot: SessionRestorableAgentSnapshot?
    let requiresNativeForkCapability: Bool
}

extension Workspace {
    func actionableAgentConversationForkTargetHarnesses(
        forPanelId panelId: UUID
    ) -> [AgentConversationForkRequest.TargetHarness] {
        actionableAgentConversationForkTargetHarnesses(
            forPanelId: panelId,
            liveAgentIndex: .shared
        )
    }

    func actionableAgentConversationForkTargetHarnesses(
        forPanelId panelId: UUID,
        liveAgentIndex: SharedLiveAgentIndex,
        targetHarnesses: [AgentConversationForkRequest.TargetHarness] = AgentConversationForkRequest.TargetHarness.liveInstalledCases
    ) -> [AgentConversationForkRequest.TargetHarness] {
        guard agentConversationTransferSnapshot(
            forPanelId: panelId,
            liveAgentIndex: liveAgentIndex
        ) != nil else {
            return []
        }
        return targetHarnesses.filter { targetHarness in
            guard targetHarness != .current else { return false }
            return agentConversationForkSelection(
                forPanelId: panelId,
                request: AgentConversationForkRequest(
                    targetHarness: targetHarness,
                    destination: .right
                ),
                liveAgentIndex: liveAgentIndex
            ) != nil
        }
    }

    func agentConversationForkSelection(
        forPanelId panelId: UUID,
        request: AgentConversationForkRequest
    ) -> WorkspaceAgentConversationForkSelection? {
        agentConversationForkSelection(
            forPanelId: panelId,
            request: request,
            liveAgentIndex: .shared
        )
    }

    func agentConversationForkSelection(
        forPanelId panelId: UUID,
        request: AgentConversationForkRequest,
        liveAgentIndex: SharedLiveAgentIndex
    ) -> WorkspaceAgentConversationForkSelection? {
        let transferSnapshot = request.targetHarness == .current
            ? nil
            : agentConversationTransferSnapshot(
                forPanelId: panelId,
                liveAgentIndex: liveAgentIndex
            )
        if let transferSnapshot,
           !request.targetHarness.usesNativeFork(for: transferSnapshot.kind) {
            return WorkspaceAgentConversationForkSelection(
                snapshot: transferSnapshot,
                validationFallbackSnapshot: nil,
                requiresNativeForkCapability: false
            )
        }

        let nativeSelection = forkAgentConversationContextMenuOpenSelection(
            forPanelId: panelId,
            liveAgentIndex: liveAgentIndex
        )
        guard nativeSelection.availability.isAvailable,
              let nativeSnapshot = nativeSelection.snapshot,
              request.targetHarness.usesNativeFork(for: nativeSnapshot.kind) else {
            guard let transferSnapshot else { return nil }
            // Named same-harness choices prefer native fork, but a deterministic
            // transcript remains actionable when that capability is unavailable.
            return WorkspaceAgentConversationForkSelection(
                snapshot: transferSnapshot,
                validationFallbackSnapshot: nil,
                requiresNativeForkCapability: false
            )
        }
        return WorkspaceAgentConversationForkSelection(
            snapshot: nativeSnapshot,
            validationFallbackSnapshot: nativeSelection.validationFallbackSnapshot,
            requiresNativeForkCapability: true
        )
    }

    func hasAgentConversationTransferSource(forPanelId panelId: UUID) -> Bool {
        agentConversationTransferSnapshot(forPanelId: panelId) != nil
    }

    func agentConversationTransferSnapshot(
        forPanelId panelId: UUID
    ) -> SessionRestorableAgentSnapshot? {
        agentConversationTransferSnapshot(
            forPanelId: panelId,
            liveAgentIndex: .shared
        )
    }

    func agentConversationTransferSnapshot(
        forPanelId panelId: UUID,
        liveAgentIndex: SharedLiveAgentIndex
    ) -> SessionRestorableAgentSnapshot? {
        guard panels[panelId] is TerminalPanel,
              !isRemoteTerminalSurface(panelId) else {
            return nil
        }
        if !allowsAgentContinuation(forPanelId: panelId),
           let observation = liveAgentIndex.index?.entry(workspaceId: id, panelId: panelId) {
            reconcileCompletedRestoredAgent(panelId: panelId, observation: observation)
        }
        guard allowsAgentContinuation(forPanelId: panelId) else { return nil }

        let liveSnapshot = liveAgentIndex.snapshotForForkConversationCandidate(
            workspaceId: id,
            panelId: panelId
        )
        let restoredSnapshot = restoredAgentSnapshotForContinuation(panelId: panelId)
        if let liveSnapshot {
            if AgentConversationSource(snapshot: liveSnapshot).hasDeterministicTranscriptSource {
                return liveSnapshot
            }
            if let restoredSnapshot,
               restoredSnapshot.kind.rawValue == liveSnapshot.kind.rawValue,
               restoredSnapshot.sessionId == liveSnapshot.sessionId,
               AgentConversationSource(snapshot: restoredSnapshot).hasDeterministicTranscriptSource {
                return restoredSnapshot
            }
            return nil
        }
        guard let restoredSnapshot,
              AgentConversationSource(snapshot: restoredSnapshot).hasDeterministicTranscriptSource else {
            return nil
        }
        return restoredSnapshot
    }
}
