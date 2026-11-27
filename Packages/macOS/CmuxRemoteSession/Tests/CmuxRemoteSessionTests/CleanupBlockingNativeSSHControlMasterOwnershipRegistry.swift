import Foundation
@testable import CmuxRemoteSession

/// Rejects cleanup ownership and records every bounded retry attempt.
final class CleanupBlockingNativeSSHControlMasterOwnershipRegistry:
    NativeSSHControlMasterOwnershipTracking,
    @unchecked Sendable
{
    let cleanupAttempts: AsyncStream<Int>
    private let continuation: AsyncStream<Int>.Continuation
    // lint:allow lock - synchronous callbacks increment one test counter.
    private let lock = NSLock()
    private var cleanupAttemptCount = 0

    init() {
        (cleanupAttempts, continuation) = AsyncStream.makeStream()
    }

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
        let attempt = lock.withLock {
            cleanupAttemptCount += 1
            return cleanupAttemptCount
        }
        continuation.yield(attempt)
        return nil
    }
}
