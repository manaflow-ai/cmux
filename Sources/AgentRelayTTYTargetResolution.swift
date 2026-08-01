import Foundation

@MainActor
extension Workspace {
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
