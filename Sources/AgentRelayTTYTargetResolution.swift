import Foundation

@MainActor
extension Workspace {
    /// Records a fresh report only when this workspace owns the surface for
    /// the relay-authenticated workspace that originally launched it.
    func registerRelayReportedTTY(
        _ ttyName: String,
        panelID: UUID,
        authenticatedWorkspaceID: UUID
    ) -> Bool {
        guard panels[panelID] is TerminalPanel,
              surfaceRegistry.remoteTTYReportOriginWorkspaceIDs[panelID] ==
                authenticatedWorkspaceID,
              remoteTerminalSessionStatesBySurfaceId[panelID]?.phase != .ended else {
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
            guard panels[surfaceID] is TerminalPanel,
                  surfaceRegistry.remoteTTYReportOriginWorkspaceIDs[surfaceID] ==
                    authenticatedWorkspaceID,
                  remoteTerminalSessionStatesBySurfaceId[surfaceID]?.phase != .ended,
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
}

@MainActor
extension AppDelegate {
    /// Routes a fresh relay report to the unique live Workspace owner without
    /// allowing the authenticated origin to change during a container move.
    func registerLiveRelayReportedTTY(
        _ ttyName: String,
        panelID: UUID,
        authenticatedWorkspaceID: UUID
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
            authenticatedWorkspaceID: authenticatedWorkspaceID
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
