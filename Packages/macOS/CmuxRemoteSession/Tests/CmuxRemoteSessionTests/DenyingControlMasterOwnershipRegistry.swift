@testable import CmuxRemoteSession

final class DenyingControlMasterOwnershipRegistry:
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

    func beginRecovery(
        controlPath: String
    ) -> NativeSSHControlMasterExclusiveUseAuthorization? {
        nil
    }

    func beginCleanup(
        controlPath: String
    ) -> NativeSSHControlMasterExclusiveUseAuthorization? {
        nil
    }
}
