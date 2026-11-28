internal import CmuxCore
internal import Foundation

/// Identifies one retained workspace generation using a resolved SSH master.
struct NativeSSHControlMasterLeaseIdentity: Hashable, Sendable {
    let ownerWorkspaceID: UUID
    let generation: UUID

    init(ownerWorkspaceID: UUID, generation: UUID) {
        self.ownerWorkspaceID = ownerWorkspaceID
        self.generation = generation
    }

    init?(configuration: WorkspaceRemoteConfiguration) {
        guard let ownerWorkspaceID = configuration.ownerWorkspaceID,
              let generation =
              configuration.sshControlMasterLeaseGeneration else {
            return nil
        }
        self.ownerWorkspaceID = ownerWorkspaceID
        self.generation = generation
    }
}
