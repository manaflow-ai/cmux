/// The outcome of acquiring the advisory lock file that arbitrates ownership of
/// a control-socket path.
///
/// Returned by ``SocketTransport/acquireSocketPathLock(for:)``. On success the
/// caller owns the lock file descriptor and must eventually release it with
/// ``SocketTransport/releaseSocketPathLock(_:)``.
public enum SocketPathLockAcquisition: Equatable, Sendable {
    /// The lock was acquired. `fd` is the locked file descriptor;
    /// `canReplaceRefusedSocket` is true when owning the lock and probing the
    /// path prove a connection-refused socket file is a leftover from a
    /// previous owner and may be unlinked before binding. The reusable marker
    /// and well-known filename rules remain compatibility signals, but are not
    /// required for crash recovery.
    case acquired(fd: Int32, canReplaceRefusedSocket: Bool)
    /// The lock could not be acquired.
    case failed(SocketStageFailure)
}
