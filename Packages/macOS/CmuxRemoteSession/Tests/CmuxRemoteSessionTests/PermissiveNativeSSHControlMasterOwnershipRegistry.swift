import Foundation
@testable import CmuxRemoteSession

/// Test fake that authorizes ownership without opening process-global locks.
final class PermissiveNativeSSHControlMasterOwnershipRegistry:
    NativeSSHControlMasterOwnershipTracking,
    @unchecked Sendable
{
    // lint:allow lock - test assertions read the retained-path snapshot.
    private let lock = NSLock()
    private var _retainedControlPaths: [String] = []

    var retainedControlPaths: [String] {
        lock.withLock { _retainedControlPaths }
    }

    func retain(
        controlPath: String,
        lease: NativeSSHControlMasterLeaseIdentity
    ) -> Bool {
        lock.withLock {
            _retainedControlPaths.append(controlPath)
        }
        return true
    }

    func release(lease: NativeSSHControlMasterLeaseIdentity) {}

    func beginRecovery(
        controlPath: String
    ) -> NativeSSHControlMasterExclusiveUseAuthorization? {
        NativeSSHControlMasterExclusiveUseAuthorization {}
    }

    func beginCleanup(
        controlPath: String
    ) -> NativeSSHControlMasterExclusiveUseAuthorization? {
        NativeSSHControlMasterExclusiveUseAuthorization {}
    }
}
