/// The outcome of attempting to bind a listener socket at a path.
///
/// Returned by ``SocketTransport/bindListenerSocket(_:path:canReplaceRefusedSocket:)``.
public enum SocketBindAttemptResult: Equatable, Sendable {
    /// The socket was bound; `identity` is the freshly created socket inode.
    case success(path: String, identity: SocketPathIdentity)
    /// The path does not fit in `sockaddr_un.sun_path`.
    case pathTooLong(path: String)
    /// A setup stage failed; ``SocketStageFailure`` carries the stage vocabulary.
    case failure(path: String, failure: SocketStageFailure)
}
