internal import Foundation

/// One resolved ControlMaster socket's in-process ownership state.
struct NativeSSHControlMasterOwnershipEntry {
    let descriptor: Int32
    var leases: Set<NativeSSHControlMasterLeaseIdentity>
    var exclusiveUseID: UUID?
}
