import Foundation

extension Workspace {
    /// Migrates a legacy binding only when its saved terminal has authoritative persistent-SSH ownership.
    func migratingLegacyPersistentSSHResumeBinding(
        _ binding: SurfaceResumeBindingSnapshot?,
        snapshotWorkspaceID: UUID,
        snapshotSurfaceID: UUID,
        persistentPTYSessionID: String?,
        restoresRemoteTerminal: Bool
    ) -> SurfaceResumeBindingSnapshot? {
        guard let binding,
              restoresRemoteTerminal,
              let persistentPTYSessionID = normalizedRemotePTYSessionID(persistentPTYSessionID),
              let configuration = remoteConfiguration,
              configuration.transport == .ssh,
              configuration.preserveAfterTerminalExit,
              !configuration.skipDaemonBootstrap,
              configuration.persistentDaemonSlot != nil else {
            return binding
        }
        return binding.migratingLegacyPersistentSSH(SurfaceResumeRemoteContext(
            workspaceID: snapshotWorkspaceID,
            surfaceID: snapshotSurfaceID,
            persistentPTYSessionID: persistentPTYSessionID
        ))
    }

    func persistentSSHResumeContext(panelID: UUID) -> SurfaceResumeRemoteContext? {
        guard let configuration = remoteConfiguration,
              configuration.transport == .ssh,
              configuration.preserveAfterTerminalExit,
              !configuration.skipDaemonBootstrap,
              configuration.persistentDaemonSlot != nil,
              activeRemoteTerminalSurfaceIds.contains(panelID) else {
            return nil
        }
        let sessionID = normalizedRemotePTYSessionID(remotePTYSessionIDsByPanelId[panelID])
            ?? Self.defaultSSHPTYSessionID(workspaceId: id, panelId: panelID)
        return SurfaceResumeRemoteContext(
            workspaceID: id,
            surfaceID: panelID,
            persistentPTYSessionID: sessionID
        )
    }

    func persistentSSHResumeCommand(
        for binding: SurfaceResumeBindingSnapshot?,
        expectedWorkspaceID: UUID,
        expectedSurfaceID: UUID,
        persistentPTYSessionID: String
    ) -> String? {
        guard let binding,
              case .persistentSSH(let context) = binding.launchFlavor,
              context.matches(
                workspaceID: expectedWorkspaceID,
                surfaceID: expectedSurfaceID,
                persistentPTYSessionID: persistentPTYSessionID
              ),
              let configuration = remoteConfiguration,
              configuration.transport == .ssh,
              configuration.preserveAfterTerminalExit,
              !configuration.skipDaemonBootstrap,
              configuration.persistentDaemonSlot != nil,
              let relayPort = configuration.relayPort,
              let startupInput = binding.remoteStartupInputWithLauncherScript(allowLauncherScript: false) else {
            return nil
        }
        return SSHPTYAttachStartupCommandBuilder.restoredRemoteShellCommand(
            relayPort: relayPort,
            initialCommand: startupInput
        )
    }

    func approvedPersistentSSHResumeCommand(
        for binding: SurfaceResumeBindingSnapshot?,
        panelID: UUID,
        persistentPTYSessionID: String
    ) -> String? {
        guard let binding else { return nil }
        let effectiveBinding = SurfaceResumeApprovalStore.applyingStoredApproval(to: binding)
        if effectiveBinding.isAgentHookBinding,
           !AgentSessionAutoResumeSettings.isEnabled(defaults: agentSessionAutoResumeDefaults) {
            return nil
        }
        guard !effectiveBinding.requiresPromptApproval,
              effectiveBinding.allowsAutomaticResume else {
            return nil
        }
        return persistentSSHResumeCommand(
            for: effectiveBinding,
            expectedWorkspaceID: id,
            expectedSurfaceID: panelID,
            persistentPTYSessionID: persistentPTYSessionID
        )
    }
}
