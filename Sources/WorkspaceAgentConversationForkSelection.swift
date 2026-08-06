import Foundation

struct WorkspaceAgentConversationForkSelection {
    let snapshot: SessionRestorableAgentSnapshot
    let validationFallbackSnapshot: SessionRestorableAgentSnapshot?
    let requiresNativeForkCapability: Bool
}

extension Workspace {
    func actionableAgentConversationForkTargets(
        forPanelId panelId: UUID
    ) -> [AgentConversationForkTarget] {
        guard let catalog = owningTabManager?.agentConversationForkTargetCatalog else {
            return []
        }
        catalog.refreshIfNeeded()
        return actionableAgentConversationForkTargets(
            forPanelId: panelId,
            liveAgentIndex: .shared,
            targets: catalog.installedTargets
        )
    }

    func actionableAgentConversationForkTargets(
        forPanelId panelId: UUID,
        liveAgentIndex: SharedLiveAgentIndex,
        targets: [AgentConversationForkTarget]
    ) -> [AgentConversationForkTarget] {
        guard agentConversationTransferSnapshot(
            forPanelId: panelId,
            liveAgentIndex: liveAgentIndex
        ) != nil else {
            return []
        }
        return targets.filter { target in
            guard target.harness != .current else { return false }
            return agentConversationForkSelection(
                forPanelId: panelId,
                request: AgentConversationForkRequest(
                    target: target,
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
        hasAgentConversationTransferSource(
            forPanelId: panelId,
            liveAgentIndex: .shared
        )
    }

    /// This read is safe from SwiftUI render and fingerprint evaluation. Live
    /// index reconciliation belongs to the explicit availability lifecycle.
    func hasAgentConversationTransferSource(
        forPanelId panelId: UUID,
        liveAgentIndex: SharedLiveAgentIndex
    ) -> Bool {
        agentConversationTransferSnapshotWithoutReconciliation(
            forPanelId: panelId,
            liveAgentIndex: liveAgentIndex
        ) != nil
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
        return agentConversationTransferSnapshotWithoutReconciliation(
            forPanelId: panelId,
            liveAgentIndex: liveAgentIndex
        )
    }

    private func agentConversationTransferSnapshotWithoutReconciliation(
        forPanelId panelId: UUID,
        liveAgentIndex: SharedLiveAgentIndex
    ) -> SessionRestorableAgentSnapshot? {
        guard panels[panelId] is TerminalPanel,
              !isRemoteTerminalSurface(panelId) else {
            return nil
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
