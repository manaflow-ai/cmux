import Foundation

extension Workspace {
    func prepareRemoteSessionForSystemSleep() {
        remotePTYSessionControllerForSocketCommand()?.prepareForSystemSleep()
    }

    func rearmRemoteSessionAfterSystemWake() {
        remotePTYSessionControllerForSocketCommand()?.resetReconnectPolicyAndReconnect(
            reason: "system wake"
        )
    }

    /// Replaces dead persistent-PTY panels with require-existing attach wrappers.
    @discardableResult
    func reattachPersistentRemotePTYPanels(requestedSurfaceId: UUID? = nil) -> Set<UUID> {
        guard remoteConfiguration?.preserveAfterTerminalExit == true else { return [] }
        let candidateIDs = requestedSurfaceId.map { Set([$0]) } ?? remoteDisconnectPlaceholderPanelIds
        var reattached = Set<UUID>()

        for panelId in candidateIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard terminalPanel(for: panelId) != nil,
                  remoteDisconnectPlaceholderPanelIds.contains(panelId) ||
                    pendingRemoteTerminalChildExitSurfaceIds.contains(panelId) ||
                    activeRemoteTerminalSurfaceIds.contains(panelId) else {
                continue
            }
            let sessionID = normalizedRemotePTYSessionID(remotePTYSessionIDsByPanelId[panelId])
                ?? Self.defaultSSHPTYSessionID(workspaceId: id, panelId: panelId)
            let resumeBinding = surfaceResumeBindingsByPanelId[panelId]
            let command = remotePTYAttachStartupCommand(sessionID: sessionID)
            guard respawnTerminalSurface(
                panelId: panelId,
                command: command,
                tmuxStartCommand: command,
                waitAfterCommand: true
            ) != nil else {
                continue
            }

            remotePTYSessionIDsByPanelId[panelId] = sessionID
            registerRemoteRelayIDAliases(remotePTYSessionID: sessionID, restoredPanelId: panelId)
            if let resumeBinding {
                surfaceResumeBindingsByPanelId[panelId] = resumeBinding
            }
            remoteDisconnectPlaceholderPanelIds.remove(panelId)
            pendingRemoteTerminalChildExitSurfaceIds.remove(panelId)
            pendingRemoteDisconnectReplacementsBySurfaceId.removeValue(forKey: panelId)
            trackRemoteTerminalSurface(panelId)
            reattached.insert(panelId)
        }
        return reattached
    }
}
