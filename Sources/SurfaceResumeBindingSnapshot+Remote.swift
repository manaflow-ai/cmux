import Foundation

extension SurfaceResumeBindingSnapshot {
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
        SurfaceResumeBindingSnapshot(
            name: name,
            kind: kind,
            command: command,
            cwd: cwd,
            checkpointId: checkpointId,
            source: source,
            environment: environment,
            autoResume: autoResume,
            approvalPolicy: approvalPolicy,
            approvalRecordId: approvalRecordId,
            launchFlavor: launchFlavor,
            updatedAt: updatedAt
        )
    }
}
