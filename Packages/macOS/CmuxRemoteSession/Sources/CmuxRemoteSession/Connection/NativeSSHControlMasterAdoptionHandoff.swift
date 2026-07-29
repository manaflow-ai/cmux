internal import Foundation

/// A temporary ownership lease that bridges foreground SSH authentication to
/// installation of the workspace's durable ControlMaster lease.
// SAFETY: `lock` serializes every read and mutation of the release closure.
public final class NativeSSHControlMasterAdoptionHandoff:
    @unchecked Sendable,
    Equatable
{
    let controlPath: String
    let lease: NativeSSHControlMasterLeaseIdentity
    // lint:allow lock - transfer, cancellation, and deinit race to release once.
    private let lock = NSLock()
    private var releaseHandler: (@Sendable () -> Void)?

    init(
        controlPath: String,
        lease: NativeSSHControlMasterLeaseIdentity,
        releaseHandler: @escaping @Sendable () -> Void
    ) {
        self.controlPath = controlPath
        self.lease = lease
        self.releaseHandler = releaseHandler
    }

    func release() {
        let handler = lock.withLock {
            defer { releaseHandler = nil }
            return releaseHandler
        }
        handler?()
    }

    /// Compares handoff identity.
    public static func == (
        lhs: NativeSSHControlMasterAdoptionHandoff,
        rhs: NativeSSHControlMasterAdoptionHandoff
    ) -> Bool {
        lhs === rhs
    }

    deinit {
        release()
    }
}
