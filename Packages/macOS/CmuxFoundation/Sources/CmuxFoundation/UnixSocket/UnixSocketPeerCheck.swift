public import Darwin

/// Verifies that the process on the other end of a connected Unix domain
/// socket runs as the expected user.
///
/// A socket path in a shared directory such as `/tmp` can be bound by any
/// local user, and checking the path with `stat` before `connect` leaves a
/// window in which the path can be swapped. Checking the connected peer with
/// `LOCAL_PEERCRED` closes both gaps, so a client runs this check after
/// `connect` succeeds and before it writes anything, credentials included:
///
/// ```swift
/// guard UnixSocketPeerCheck().isTrustedPeer(fd) else {
///     close(fd)
///     throw CLIError(message: "Socket peer is not owned by the current user")
/// }
/// ```
public struct UnixSocketPeerCheck: Sendable, Equatable {
    /// The user ID the peer must run as.
    public let expectedUserID: uid_t

    /// Creates a check for the given peer user ID.
    ///
    /// - Parameter expectedUserID: The user ID the peer must run as. Defaults
    ///   to this process's effective user ID, the owner of any socket this
    ///   process binds. Tests pass a different ID to exercise refusal without
    ///   a second local account.
    public init(expectedUserID: uid_t = geteuid()) {
        self.expectedUserID = expectedUserID
    }

    /// The effective user ID of the connected peer, via `LOCAL_PEERCRED`.
    ///
    /// The kernel records the peer's credentials at connect time, so the
    /// lookup still works after the peer disconnects.
    /// - Parameter socket: A connected Unix domain socket descriptor.
    /// - Returns: The peer's effective user ID, or `nil` when the descriptor
    ///   is not a connected local socket.
    public func peerUserID(of socket: Int32) -> uid_t? {
        var credentials = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &length) == 0,
              credentials.cr_version == UInt32(XUCRED_VERSION) else {
            return nil
        }
        return credentials.cr_uid
    }

    /// Whether the connected peer runs as ``expectedUserID``.
    ///
    /// - Parameter socket: A connected Unix domain socket descriptor.
    /// - Returns: `true` only when the peer's credentials could be read and
    ///   its user ID matches; any lookup failure refuses the peer.
    public func isTrustedPeer(_ socket: Int32) -> Bool {
        peerUserID(of: socket) == expectedUserID
    }
}
