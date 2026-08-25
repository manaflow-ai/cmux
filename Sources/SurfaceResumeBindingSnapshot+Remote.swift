import CMUXAgentLaunch
import Foundation

extension SurfaceResumeBindingSnapshot {
    /// Allows a persistent-SSH transport reattach when exact policy intentionally omits input.
    var permitsTransportOnlyPersistentSSHRestore: Bool {
        isAgentHookBinding &&
            launchFlavor.remoteContext != nil &&
            restoreWorkingDirectorySelection?.discardsRecordedCwdOptions == true &&
            hasCompleteManagedSessionIdentity
    }

    /// Assigns persistent-SSH ownership and fails closed for legacy agent-hook cwd policy.
    func migratingLegacyPersistentSSH(_ context: SurfaceResumeRemoteContext) -> SurfaceResumeBindingSnapshot {
        let migrated = wasDecodedWithoutLaunchFlavor
            ? replacingLaunchFlavor(.persistentSSH(context))
            : self
        guard migrated.isAgentHookBinding,
              migrated.restoreWorkingDirectorySelection == nil,
              migrated.launchFlavor.remoteContext != nil else {
            return migrated
        }
        return migrated.invalidatingAgentRestoreRecipe()
    }

    /// Persists authenticated relay ownership and the relay-reported cwd trust boundary.
    func registeredForPersistentSSH(
        _ context: SurfaceResumeRemoteContext,
        restorableAgent: SessionRestorableAgentSnapshot? = nil
    ) -> SurfaceResumeBindingSnapshot {
        var registered = replacingLaunchFlavor(.persistentSSH(context))
        if registered.isAgentHookBinding {
            let kind = restorableAgent?.kind.rawValue ?? registered.kind ?? ""
            if registered.cwd != nil {
                registered.restoreWorkingDirectorySelection = .exact(registered.cwd)
            } else if restorableAgent?.registration?.cwd == .ignore ||
                        AgentResumeWorkingDirectory().cwdNamespacing(forKind: kind) == .cwdInFile {
                registered.restoreWorkingDirectorySelection = .exact(nil)
            } else {
                registered.restoreWorkingDirectorySelection = .unavailable
            }
        }
        return registered
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
