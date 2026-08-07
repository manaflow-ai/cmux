import Foundation

extension SurfaceResumeBindingSnapshot {
    /// An authenticated persistent-SSH agent hook is the remote equivalent of
    /// a locally confirmed process. Session-end handling retires or clears the
    /// binding, so an auto-resume binding that still owns the live PTY is the
    /// authoritative running-session fact when no local PID can exist.
    func recordsRunningPersistentSSHAgent(
        in expectedContext: SurfaceResumeRemoteContext?
    ) -> Bool {
        guard isAgentHookBinding,
              hasCompleteManagedSessionIdentity,
              allowsAutomaticResume,
              let expectedContext,
              case .persistentSSH(let storedContext) = launchFlavor else {
            return false
        }
        return storedContext.matches(
            workspaceID: expectedContext.workspaceID,
            surfaceID: expectedContext.surfaceID,
            persistentPTYSessionID: expectedContext.persistentPTYSessionID
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
