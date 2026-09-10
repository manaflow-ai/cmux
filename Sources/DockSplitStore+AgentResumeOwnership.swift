import Foundation

extension DockSplitStore {
    /// Dock twin of `Workspace.restoredAgentHasLiveProcess(_:panelId:)`.
    ///
    /// Without a restored snapshot, the hook-published binding supplies the
    /// agent identity; the Dock's runtime table supplies the hook-registered
    /// process. The evidence order itself lives in `RestoredAgentLiveness`.
    func restoredAgentHasLiveProcess(
        panelId: UUID,
        restoredAgent: SessionRestorableAgentSnapshot?
    ) -> Bool {
        let binding = surfaceResumeBindingsByPanelId[panelId]
            ?? managedAgentResumeBindingsByPanelId[panelId]
        guard let agent = restoredAgent
            ?? binding.flatMap({ $0.isAgentHookBinding ? $0.managedRestorableAgentSnapshot(replacing: nil) : nil })
        else {
            return false
        }
        let pidKey = RestoredAgentLiveness.pidKey(for: agent)
        let runtime = agentRuntimeByPanelId[panelId]
            ?? detachedSurfaceTransfersByPanelId[panelId]?.agentRuntime
        let recordedProcess = runtime?.agentPIDs[pidKey].map { pid in
            RestoredAgentLiveness.RecordedProcess(
                pid: pid,
                identity: runtime?.agentPIDProcessIdentities[pidKey]
            )
        }
        return RestoredAgentLiveness().hasLiveProcess(
            agent,
            workspaceId: detachedSurfaceTransfersByPanelId[panelId]?.sessionRestoreWorkspaceId
                ?? workspaceId,
            panelId: panelId,
            recordedProcess: recordedProcess,
            liveIndex: SharedLiveAgentIndex.shared.index,
            foregroundProcessID: (panels[panelId] as? TerminalPanel)?.surface.foregroundProcessID()
        )
    }

    func markRestoredAgentCompleted(panelId: UUID) {
        // A live completion belongs to the current session generation. Keep
        // older cached metadata invalidated, but no longer classify this
        // current tombstone as the cached generation that was replaced.
        replacedCachedTransferAgentSessionPanelIds.remove(panelId)
        let runtimeIdentities = Set(
            (agentRuntimeByPanelId[panelId]
                ?? detachedSurfaceTransfersByPanelId[panelId]?.agentRuntime)?
                .agentPIDProcessIdentities.values.map { $0 } ?? []
        )
        restoredAgentLifecycle.markCompleted(
            panelId: panelId,
            observation: SharedLiveAgentIndex.shared.index?.entry(
                workspaceId: detachedSurfaceTransfersByPanelId[panelId]?.sessionRestoreWorkspaceId
                    ?? workspaceId,
                panelId: panelId
            ),
            runtimeProcessIdentities: runtimeIdentities
        )
    }

}
