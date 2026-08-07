import CmuxWorkspaces
import Foundation

extension SurfaceResumeBindingSnapshot {
    /// Returns whether current remote runtime facts prove this exact binding's
    /// agent command is still active. Binding/PTTY ownership alone is durable
    /// historical state, so liveness additionally requires a connected attach,
    /// a running shell command, and an exact session-scoped hook runtime key.
    func recordsLivePersistentSSHAgent(
        in authoritativelyConnectedContext: SurfaceResumeRemoteContext?,
        shellActivityState: PanelShellActivityState?,
        agentPIDKeys: Set<String>
    ) -> Bool {
        guard isAgentHookBinding,
              hasCompleteManagedSessionIdentity,
              let authoritativelyConnectedContext,
              shellActivityState == .commandRunning,
              agentPIDKeys.contains(where: matchesExactAgentRuntimeKey),
              case .persistentSSH(let storedContext) = launchFlavor else {
            return false
        }
        return storedContext.matches(
            workspaceID: authoritativelyConnectedContext.workspaceID,
            surfaceID: authoritativelyConnectedContext.surfaceID,
            persistentPTYSessionID: authoritativelyConnectedContext.persistentPTYSessionID
        )
    }

    /// Matches the exact session-scoped runtime ownership key for this binding.
    func matchesExactAgentRuntimeKey(_ key: String) -> Bool {
        guard let identity = managedAgentRuntimeIdentity else { return false }
        return Self.runtimeAgentKey(
            key,
            matches: identity.kind,
            checkpointID: identity.checkpointID
        )
    }

    /// Matches runtime state this binding owns, including its legacy kind slot.
    ///
    /// The kind-only representation cannot prove liveness, but prompt/end
    /// cleanup still consumes it so mixed-version hooks do not leave status or
    /// lifecycle state behind.
    func matchesAgentRuntimeKeyForCleanup(_ key: String) -> Bool {
        guard let identity = managedAgentRuntimeIdentity else { return false }
        return key == identity.kind.lifecycleStatusKey || matchesExactAgentRuntimeKey(key)
    }

    private var managedAgentRuntimeIdentity: (
        kind: RestorableAgentKind,
        checkpointID: String
    )? {
        guard isAgentHookBinding,
              hasCompleteManagedSessionIdentity,
              let kindValue = kind?.trimmingCharacters(in: .whitespacesAndNewlines),
              let agentKind = RestorableAgentKind(rawValue: kindValue),
              let checkpointID = checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        return (agentKind, checkpointID)
    }

    /// Runtime agent keys are session-scoped (`<status-key>.<session-id>`).
    /// A kind-only key cannot prove which saved conversation is still active.
    private static func runtimeAgentKey(
        _ key: String,
        matches kind: RestorableAgentKind,
        checkpointID: String
    ) -> Bool {
        let prefix = "\(kind.lifecycleStatusKey)."
        guard key.hasPrefix(prefix) else { return false }
        return ManagedAgentSessionIdentity.sessionIDsMatch(
            kind: kind.rawValue,
            lhs: String(key.dropFirst(prefix.count)),
            rhs: checkpointID
        )
    }

    /// Assigns trusted persistent-SSH ownership only to a legacy decoded binding.
    func migratingLegacyPersistentSSH(_ context: SurfaceResumeRemoteContext) -> SurfaceResumeBindingSnapshot {
        guard wasDecodedWithoutLaunchFlavor else { return self }
        return registeredForPersistentSSH(context)
    }

    func registeredForPersistentSSH(_ context: SurfaceResumeRemoteContext) -> SurfaceResumeBindingSnapshot {
        replacingLaunchFlavor(.persistentSSH(context))
    }

    func retargetingRemoteOwner(
        expectedWorkspaceID: UUID,
        expectedSurfaceID: UUID,
        workspaceID: UUID,
        surfaceID: UUID,
        persistentPTYSessionID: String?
    ) -> SurfaceResumeBindingSnapshot {
        guard case .persistentSSH(let context) = launchFlavor,
              let persistentPTYSessionID,
              context.matches(
                workspaceID: expectedWorkspaceID,
                surfaceID: expectedSurfaceID,
                persistentPTYSessionID: persistentPTYSessionID
              ) else {
            return self
        }
        return replacingLaunchFlavor(.persistentSSH(context.retargeted(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            persistentPTYSessionID: persistentPTYSessionID
        )))
    }

    private func replacingLaunchFlavor(
        _ launchFlavor: SurfaceResumeLaunchFlavor
    ) -> SurfaceResumeBindingSnapshot {
        var replaced = self
        replaced.launchFlavor = launchFlavor
        return replaced
    }
}
