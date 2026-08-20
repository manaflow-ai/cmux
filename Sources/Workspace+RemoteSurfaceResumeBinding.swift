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
              let startupInput = binding.remoteStartupInput() else {
            return nil
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
        if effectiveBinding.isAgentHookBinding || effectiveBinding.isRemoteSynthesized,
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

    /// Synthesizes (and registers) a hookless directory-scoped continue
    /// binding after the daemon confirmed a persistent PTY session died
    /// (#7989), using the foreground tombstone the daemon sampled before the
    /// death. Returns the remote shell command the replacement session must
    /// run to resume the agent, or nil when facts or policy say plain shell:
    /// an existing binding always wins (its approved command is returned),
    /// the tombstone must name a known agent executable (shells never
    /// resume), and the result passes the same approval and auto-resume
    /// gates as every other persistent-SSH resume command.
    func remoteContinueResumeCommandAfterSessionLoss(
        panelId: UUID,
        persistentPTYSessionID: String,
        foregroundCommand: String?,
        foregroundCwd: String?
    ) -> String? {
        let sessionID = persistentPTYSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty,
              let configuration = remoteConfiguration,
              configuration.transport == .ssh,
              configuration.preserveAfterTerminalExit,
              !configuration.skipDaemonBootstrap,
              configuration.persistentDaemonSlot != nil else {
            return nil
        }
        // An existing binding (agent-hook / cli / process-detected /
        // previously synthesized) always wins; synthesis only fills the gap.
        if let existing = surfaceResumeBindingsByPanelId[panelId] {
            return approvedPersistentSSHResumeCommand(
                for: existing,
                panelID: panelId,
                persistentPTYSessionID: sessionID
            )
        }
        guard let executable = Self.normalizedForegroundExecutableName(foregroundCommand),
              !TerminalForegroundCommandCapture.isShellProcessName(executable),
              let kindRawValue = TerminalForegroundCommandCapture.knownAgentKind(forExecutableName: executable),
              let kind = RestorableAgentKind(rawValue: kindRawValue),
              let binding = RemoteAgentContinueSynthesizer.binding(
                  kind: kind,
                  remoteWorkingDirectory: foregroundCwd,
                  remoteContext: SurfaceResumeRemoteContext(
                      workspaceID: id,
                      surfaceID: panelId,
                      persistentPTYSessionID: sessionID
                  )
              ),
              let command = approvedPersistentSSHResumeCommand(
                  for: binding,
                  panelID: panelId,
                  persistentPTYSessionID: sessionID
              ) else {
            return nil
        }
        surfaceResumeBindingsByPanelId[panelId] = binding
        return command
    }

    /// Basename of the daemon-sampled foreground command, or nil when empty.
    private static func normalizedForegroundExecutableName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let basename = (raw as NSString).lastPathComponent
        return basename.isEmpty ? nil : basename
    }
}
