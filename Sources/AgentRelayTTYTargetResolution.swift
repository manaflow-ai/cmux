import Foundation

@MainActor
extension Workspace {
    /// Records a fresh report only when this workspace owns the surface for
    /// the relay-authenticated workspace that originally launched it.
    func registerRelayReportedTTY(
        _ ttyName: String,
        panelID: UUID,
        authenticatedWorkspaceID: UUID,
        terminalLifecycleID: UUID,
        attemptID: UUID
    ) -> Bool {
        guard let terminal = panels[panelID] as? TerminalPanel,
              surfaceRegistry.remoteTTYReportOriginWorkspaceIDs[panelID] ==
                authenticatedWorkspaceID,
              terminal.surface.terminalLifecycleId == terminalLifecycleID,
              remoteTerminalAttemptIDsBySurfaceId[panelID] == attemptID else {
            return false
        }
        registerReportedSurfaceTTYName(ttyName, panelId: panelID)
        if isRemoteWorkspace {
            syncRemotePortScanTTYs()
            _ = applyPendingRemoteSurfacePortKickIfNeeded(to: panelID)
        }
        return true
    }

    /// Fresh remote TTY reports whose authenticated relay origin matches the
    /// requested workspace. The binding points at the surface's current owner.
    func runtimeReportedRemoteTTYCandidates(
        authenticatedWorkspaceID: UUID
    ) -> [(binding: TerminalCallerTTYBinding, ttyName: String)] {
        surfaceRegistry.runtimeReportedTTYSurfaceIDs.compactMap { surfaceID in
            guard let terminal = panels[surfaceID] as? TerminalPanel,
                  hasCurrentRuntimeReportedTTY(panelId: surfaceID, terminal: terminal),
                  surfaceRegistry.remoteTTYReportOriginWorkspaceIDs[surfaceID] ==
                    authenticatedWorkspaceID,
                  let ttyName = surfaceRegistry.surfaceTTYNames[surfaceID] else {
                return nil
            }
            return (
                binding: TerminalCallerTTYBinding(
                    workspaceId: id,
                    surfaceId: surfaceID
                ),
                ttyName: ttyName
            )
        }
    }

    /// Resolves one authenticated remote workspace without inspecting another
    /// relay's TTY namespace.
    func agentDeliveryTarget(forReportedTTYName ttyName: String) -> AgentDeliveryTargetCandidate? {
        guard isRemoteWorkspace else { return nil }
        var candidates = runtimeReportedRemoteTTYCandidates(
            authenticatedWorkspaceID: id
        )
        for dock in DockSplitStore.liveRemoteTerminalStores(
            presentationWorkspaceID: id
        ) {
            candidates.append(contentsOf: dock.runtimeReportedRemoteTTYCandidates(
                presentationWorkspaceID: id
            ))
        }
        let resolver = TerminalCallerTTYResolver(reportedCandidates: candidates)
        guard let binding = resolver.binding(for: ttyName) else { return nil }
        return AgentDeliveryTargetCandidate(
            workspaceId: binding.workspaceId,
            surfaceId: binding.surfaceId
        )
    }

    /// Keeps the launch attempt with a live remote terminal even when its new
    /// container is an ordinary workspace with no remote configuration.
    func restoreTransferredRelayTTYIdentity(from transfer: DetachedSurfaceTransfer) {
        guard transfer.isRemoteTerminal,
              transfer.remoteTerminalSessionPhase != .ended,
              let attemptID = transfer.remoteTerminalAttemptID else {
            remoteTerminalAttemptIDsBySurfaceId.removeValue(forKey: transfer.panelId)
            return
        }
        remoteTerminalAttemptIDsBySurfaceId[transfer.panelId] = attemptID
    }
}

@MainActor
extension AppDelegate {
    /// Routes a fresh relay report to the unique live Workspace owner without
    /// allowing the authenticated origin to change during a container move.
    func registerLiveRelayReportedTTY(
        _ ttyName: String,
        panelID: UUID,
        authenticatedWorkspaceID: UUID,
        terminalLifecycleID: UUID,
        attemptID: UUID
    ) -> Bool {
        let owners = agentDeliveryTabManagers().flatMap(\.tabs).filter {
            $0.panels[panelID] != nil
                && $0.surfaceRegistry.remoteTTYReportOriginWorkspaceIDs[panelID] ==
                    authenticatedWorkspaceID
        }
        guard owners.count == 1 else { return false }
        return owners[0].registerRelayReportedTTY(
            ttyName,
            panelID: panelID,
            authenticatedWorkspaceID: authenticatedWorkspaceID,
            terminalLifecycleID: terminalLifecycleID,
            attemptID: attemptID
        )
    }

    /// Resolves a relay-authenticated TTY across the live containers that may
    /// now own a surface launched by that remote workspace.
    func liveRelayAgentDeliveryTarget(
        authenticatedWorkspaceID: UUID,
        ttyName: String
    ) -> AgentDeliveryTargetCandidate? {
        var candidates: [(binding: TerminalCallerTTYBinding, ttyName: String)] = []
        for manager in agentDeliveryTabManagers() {
            for workspace in manager.tabs {
                candidates.append(contentsOf: workspace.runtimeReportedRemoteTTYCandidates(
                    authenticatedWorkspaceID: authenticatedWorkspaceID
                ))
            }
        }
        for dock in DockSplitStore.liveRemoteTerminalStores(
            presentationWorkspaceID: authenticatedWorkspaceID
        ) {
            candidates.append(contentsOf: dock.runtimeReportedRemoteTTYCandidates(
                presentationWorkspaceID: authenticatedWorkspaceID
            ))
        }
        let resolver = TerminalCallerTTYResolver(reportedCandidates: candidates)
        guard let binding = resolver.binding(for: ttyName) else { return nil }
        return AgentDeliveryTargetCandidate(
            workspaceId: binding.workspaceId,
            surfaceId: binding.surfaceId
        )
    }
}
