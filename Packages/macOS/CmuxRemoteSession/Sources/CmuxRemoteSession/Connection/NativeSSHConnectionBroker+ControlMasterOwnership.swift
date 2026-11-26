public import CmuxCore
public import Foundation

@MainActor
extension NativeSSHConnectionBroker {
    /// Begins an ownership handoff while foreground SSH authentication still
    /// holds the resolved ControlPath authentication lock.
    ///
    /// The returned lease prevents another live cmux process from recovering
    /// an inherited forward on the newly authenticated master before the
    /// workspace configuration is ready to adopt it.
    ///
    /// - Parameters:
    ///   - controlPath: Exact resolved cmux-owned ControlPath.
    ///   - ownerWorkspaceID: Workspace that is authenticating the master.
    /// - Returns: A handoff lease, or `nil` when ownership cannot be acquired.
    public func beginControlMasterAdoption(
        controlPath: String,
        ownerWorkspaceID: UUID
    ) -> NativeSSHControlMasterAdoptionHandoff? {
        let normalizedControlPath =
            controlPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedControlPath == controlPath,
              sharingOptions.resolvedControlMasterOwnershipLockPath(
                  controlPath: controlPath
              ) != nil else {
            return nil
        }
        let lease = NativeSSHControlMasterLeaseIdentity(
            ownerWorkspaceID: ownerWorkspaceID,
            generation: UUID()
        )
        guard controlMasterOwnershipRegistry.retain(
            controlPath: controlPath,
            lease: lease
        ) else {
            return nil
        }
        let ownershipRegistry = controlMasterOwnershipRegistry
        return NativeSSHControlMasterAdoptionHandoff(
            controlPath: controlPath,
            lease: lease,
            clock: clock,
            releaseHandler: {
                ownershipRegistry.release(lease: lease)
            }
        )
    }

    /// Atomically transfers a foreground-authentication handoff to the
    /// workspace's retained configuration lease.
    ///
    /// The durable lease is acquired before the temporary lease is released,
    /// so another process never observes an unowned master between phases.
    ///
    /// - Parameters:
    ///   - handoff: Temporary lease returned by
    ///     ``beginControlMasterAdoption(controlPath:ownerWorkspaceID:)``.
    ///   - configuration: Retained workspace configuration receiving ownership.
    /// - Returns: `true` when the durable lease acquired ownership.
    public func completeControlMasterAdoption(
        _ handoff: NativeSSHControlMasterAdoptionHandoff,
        configuration: WorkspaceRemoteConfiguration
    ) -> Bool {
        guard configuration.ownerWorkspaceID ==
                handoff.lease.ownerWorkspaceID,
              let lease = NativeSSHControlMasterLeaseIdentity(
                  configuration: configuration
              ),
              controlMasterOwnershipRegistry.retain(
                  controlPath: handoff.controlPath,
                  lease: lease
              ) else {
            return false
        }
        handoff.release()
        return true
    }

    /// Releases a foreground-authentication handoff that will not be adopted.
    ///
    /// - Parameter handoff: Temporary lease to release.
    public func cancelControlMasterAdoption(
        _ handoff: NativeSSHControlMasterAdoptionHandoff
    ) {
        handoff.release()
    }
}
