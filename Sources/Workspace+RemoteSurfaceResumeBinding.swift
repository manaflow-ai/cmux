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
        persistentPTYSessionID: String,
        restorableAgent: SessionRestorableAgentSnapshot? = nil
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
              let relayPort = configuration.relayPort else {
            return nil
        }
        let matchingRestorableAgent = (restorableAgent ?? restoredAgentSnapshotsByPanelId[expectedSurfaceID]).flatMap {
            Self.restorableAgentForSessionRestore($0, resumeBinding: binding)
        }
        let bindingForStartup: SurfaceResumeBindingSnapshot = if let selection =
            binding.restoreWorkingDirectorySelection,
            selection.discardsRecordedCwdOptions,
            let matchingRestorableAgent {
            binding.applyingRestoreWorkingDirectorySelection(
                selection,
                from: matchingRestorableAgent
            )
        } else {
            binding
        }
        let startupInput: String?
        if bindingForStartup.restoreWorkingDirectorySelection?.discardsRecordedCwdOptions == true {
            // Exact/unavailable policies may intentionally have no structured
            // launch recipe. Keep the transport reattach, but never replay the
            // untrusted stored shell command in that case.
            startupInput = bindingForStartup.remoteStartupInput(
                registration: matchingRestorableAgent?.registration
            )
        } else if bindingForStartup.isAgentHookBinding && bindingForStartup.restoreWorkingDirectorySelection == nil {
            startupInput = nil
        } else {
            guard let input = bindingForStartup.remoteStartupInput(
                registration: matchingRestorableAgent?.registration
            ) else { return nil }
            startupInput = input
        }
        return SSHPTYAttachStartupCommandBuilder.restoredRemoteShellCommand(
            relayPort: relayPort,
            initialCommand: startupInput,
            configuredRemoteCommand: configuration.configuredRemoteCommand
        )
    }

    func approvedPersistentSSHResumeCommand(
        for binding: SurfaceResumeBindingSnapshot?,
        panelID: UUID,
        persistentPTYSessionID: String
    ) -> String? {
        guard let binding else { return nil }
        guard case let .resolved(effectiveBinding) = SurfaceResumeApprovalStore.applyingStoredApprovalLookup(
            to: binding
        ) else {
            return nil
        }
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
