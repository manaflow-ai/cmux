/// The outcome of acquiring the advisory lock file that arbitrates ownership of
/// a control-socket path.
///
/// Returned by ``SocketTransport/acquireSocketPathLock(for:)``. On success the
/// caller owns the lock file descriptor and must eventually release it with
/// ``SocketTransport/releaseSocketPathLock(_:)``.
public enum SocketPathLockAcquisition: Equatable, Sendable {
    /// The lock was acquired. `fd` is the locked file descriptor;
    /// `canReplaceRefusedSocket` is true when the lock (or the socket filename
    /// policy) proves a connection-refused socket file at the path is a leftover
    /// from a previous owner and may be unlinked before binding.
    case acquired(fd: Int32, canReplaceRefusedSocket: Bool)
    /// The lock could not be acquired.
    case failed(SocketStageFailure)
}
