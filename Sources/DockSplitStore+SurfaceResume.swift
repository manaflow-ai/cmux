import Foundation

extension DockSplitStore {
    @discardableResult
    func setSurfaceResumeBinding(
        _ binding: SurfaceResumeBindingSnapshot,
        panelId: UUID,
        agentEventTime: TimeInterval? = nil
    ) -> Bool {
        guard acceptsSurfaceResumeBindingMutation(
            panelId: panelId,
            agentEventTime: agentEventTime
        ),
              panels[panelId] is TerminalPanel,
              let startupInput = binding.inlineStartupInput(repairPortableAgentExecutable: false),
              !startupInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        surfaceResumeBindingsByPanelId[panelId] = binding
        recordSurfaceResumeBindingMutation(panelId: panelId, eventTime: binding.updatedAt)
        return true
    }

    @discardableResult
    func clearSurfaceResumeBinding(
        panelId: UUID,
        eventTime: TimeInterval? = nil
    ) -> Bool {
        let removed = surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
        recordSurfaceResumeBindingMutation(
            panelId: panelId,
            eventTime: eventTime ?? Date.now.timeIntervalSince1970
        )
        return removed != nil
    }

    func surfaceResumeBinding(panelId: UUID) -> SurfaceResumeBindingSnapshot? {
        surfaceResumeBindingsByPanelId[panelId]
    }

    func acceptsSurfaceResumeBindingMutation(panelId: UUID, agentEventTime: TimeInterval?) -> Bool {
        guard let agentEventTime else { return true }
        let currentBindingTime = surfaceResumeBindingsByPanelId[panelId]?.updatedAt
        let orderingWatermark = [surfaceResumeBindingEventTimesByPanelId[panelId], currentBindingTime]
            .compactMap { $0 }
            .max()
        guard let orderingWatermark else { return true }
        return agentEventTime >= orderingWatermark
    }

    func recordSurfaceResumeBindingMutation(panelId: UUID, eventTime: TimeInterval) {
        if let current = surfaceResumeBindingEventTimesByPanelId[panelId], current >= eventTime {
            return
        }
        surfaceResumeBindingEventTimesByPanelId[panelId] = eventTime
    }

    func persistentSSHResumeRegistration(
        panelId: UUID
    ) -> (context: SurfaceResumeRemoteContext, relayToken: String)? {
        guard let transfer = detachedSurfaceTransfersByPanelId[panelId],
              transfer.isRemoteTerminal,
              let sessionID = transfer.remotePTYSessionID?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return nil
        }
        let sourceWorkspaceId = transfer.sessionRestoreWorkspaceId
        let sourceWorkspace = AppDelegate.shared?.workspaceFor(tabId: sourceWorkspaceId)
        guard let configuration = transfer.remoteCleanupConfiguration ?? sourceWorkspace?.remoteConfiguration,
              configuration.transport == .ssh,
              configuration.preserveAfterTerminalExit,
              !configuration.skipDaemonBootstrap,
              configuration.persistentDaemonSlot != nil,
              let relayToken = configuration.relayToken else {
            return nil
        }
        return (
            SurfaceResumeRemoteContext(
                workspaceID: sourceWorkspaceId,
                surfaceID: panelId,
                persistentPTYSessionID: sessionID
            ),
            relayToken
        )
    }
}
