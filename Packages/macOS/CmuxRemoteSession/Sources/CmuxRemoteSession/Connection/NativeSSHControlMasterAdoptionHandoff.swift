internal import CmuxRemoteWorkspace
internal import Foundation

/// A temporary ownership lease that bridges foreground SSH authentication to
/// installation of the workspace's durable ControlMaster lease. Unconsumed
/// handoffs expire so an interrupted restore cannot retain ownership forever.
///
/// The synchronous lock serializes the release closure and expiration task.
public final class NativeSSHControlMasterAdoptionHandoff:
    @unchecked Sendable,
    Equatable
{
    /// Exact cmux-owned ControlPath held by this adoption lease.
    public let controlPath: String
    let lease: NativeSSHControlMasterLeaseIdentity
    // lint:allow lock - transfer, cancellation, and deinit race to release once.
    private let lock = NSLock()
    private var releaseHandler: (@Sendable () -> Void)?
    private var expirationTask: Task<Void, Never>? = nil

    init(
        controlPath: String,
        lease: NativeSSHControlMasterLeaseIdentity,
        clock: any RemoteProxyRetryClock,
        expirationMilliseconds: Int = 30_000,
        releaseHandler: @escaping @Sendable () -> Void
    ) {
        self.controlPath = controlPath
        self.lease = lease
        self.releaseHandler = releaseHandler
        self.expirationTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(
                    forMilliseconds: expirationMilliseconds
                )
            } catch {
                return
            }
            self?.release()
        }
    }

    func release() {
        let (handler, expirationTask) = lock.withLock {
            let result = (releaseHandler, self.expirationTask)
            releaseHandler = nil
            self.expirationTask = nil
            return result
        }
        expirationTask?.cancel()
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
