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

    func markPersistentRemotePTYAttachFailed(surfaceId: UUID) {
        guard remoteConfiguration?.preserveAfterTerminalExit == true else { return }
        let previousPresentedDirectory = presentedCurrentDirectory
        let sessionEnded = endedPersistentRemotePTYAttachSurfaceIds.contains(surfaceId)
        if !sessionEnded {
            remotePTYSessionIDsByPanelId[surfaceId] = persistentRemotePTYSessionIDForRestart(panelId: surfaceId)
        }
        remoteDisconnectPlaceholderPanelIds.insert(surfaceId)
        pendingRemoteTerminalChildExitSurfaceIds.remove(surfaceId)
        cancelPendingRemoteDisconnectReplacement(surfaceId: surfaceId)
        transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: surfaceId)
        surfaceTTYNames.removeValue(forKey: surfaceId)
        let removedTrustedDirectory = clearRemoteDirectoryReportForPersistentPTYFailure(surfaceId: surfaceId)
        if !sessionEnded { trackRemoteTerminalSurface(surfaceId) }
        syncRemotePortScanTTYs()
        refreshPersistentPTYFailurePresentation(
            previousDirectory: previousPresentedDirectory,
            removedTrustedDirectory: removedTrustedDirectory
        )
    }

    /// Replaces dead persistent-PTY panels with require-existing attach wrappers.
    @discardableResult
    func reattachPersistentRemotePTYPanels(
        requestedSurfaceId: UUID? = nil,
        restartEndedSessions: Bool = false
    ) -> Set<UUID> {
        guard let configuration = remoteConfiguration,
              configuration.preserveAfterTerminalExit == true else { return [] }
        let candidateIDs = requestedSurfaceId.map { Set([$0]) } ?? remoteDisconnectPlaceholderPanelIds
        var reattached = Set<UUID>()

        for panelId in candidateIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard terminalPanel(for: panelId) != nil,
                  remoteDisconnectPlaceholderPanelIds.contains(panelId) ||
                    pendingRemoteTerminalChildExitSurfaceIds.contains(panelId) ||
                    activeRemoteTerminalSurfaceIds.contains(panelId) else {
                continue
            }
            let sessionID = persistentRemotePTYSessionIDForRestart(panelId: panelId)
            let resumeBinding = surfaceResumeBindingsByPanelId[panelId]
            let sessionEnded = endedPersistentRemotePTYAttachSurfaceIds.contains(panelId)
            guard restartEndedSessions || !sessionEnded else { continue }
            let command: String
            let usesPersistentSSHPTY = configuration.transport == .ssh &&
                !configuration.skipDaemonBootstrap && configuration.persistentDaemonSlot != nil
            if usesPersistentSSHPTY {
                command = remotePTYAttachStartupCommand(
                    sessionID: sessionID,
                    requireExisting: !sessionEnded
                )
            } else {
                guard let startupCommand = effectiveRemoteTerminalStartupCommand(from: configuration) else {
                    continue
                }
                command = startupCommand
            }
            let finalizeReattach: @MainActor (TerminalPanel) -> Void = { [weak self] _ in
                guard let self else { return }
                self.remotePTYSessionIDsByPanelId[panelId] = sessionID
                self.registerRemoteRelayIDAliases(
                    remotePTYSessionID: sessionID,
                    restoredPanelId: panelId
                )
                if let resumeBinding {
                    self.surfaceResumeBindingsByPanelId[panelId] = resumeBinding
                }
                self.remoteDisconnectPlaceholderPanelIds.remove(panelId)
                self.pendingRemoteTerminalChildExitSurfaceIds.remove(panelId)
                self.pendingRemoteDisconnectReplacementsBySurfaceId
                    .removeValue(forKey: panelId)
                self.endedPersistentRemotePTYAttachSurfaceIds.remove(panelId)
                self.trackRemoteTerminalSurface(panelId)
            }
            let outcome = requestRespawnTerminalSurface(
                panelId: panelId,
                command: command,
                tmuxStartCommand: command,
                waitAfterCommand: true,
                onReady: finalizeReattach
            )
            if case .failed = outcome {
                continue
            }
            reattached.insert(panelId)
        }
        return reattached
    }

    private func persistentRemotePTYSessionIDForRestart(panelId: UUID) -> String {
        if let mappedSessionID = normalizedRemotePTYSessionID(remotePTYSessionIDsByPanelId[panelId]) {
            return mappedSessionID
        }
        if let inheritedSessionID = normalizedRemotePTYSessionID(
            terminalPanel(for: panelId)?.surface.respawnAdditionalEnvironment[Self.remotePTYSessionEnvironmentKey]
        ) {
            return inheritedSessionID
        }
        return Self.defaultSSHPTYSessionID(workspaceId: id, panelId: panelId)
    }
}
