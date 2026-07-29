import Foundation
@testable import CmuxRemoteSession

/// Test fake that authorizes ownership without opening process-global locks.
final class PermissiveNativeSSHControlMasterOwnershipRegistry:
    NativeSSHControlMasterOwnershipTracking,
    Sendable
{
    func retain(
        controlPath: String,
        lease: NativeSSHControlMasterLeaseIdentity
    ) -> Bool {
        true
    }

    func release(lease: NativeSSHControlMasterLeaseIdentity) {}

    func beginReset(
        controlPath: String
    ) -> NativeSSHControlMasterResetAuthorization? {
        NativeSSHControlMasterResetAuthorization {}
    }
}
