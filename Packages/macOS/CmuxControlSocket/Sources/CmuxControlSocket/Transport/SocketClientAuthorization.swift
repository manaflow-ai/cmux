public import Darwin

/// Authorizes peer processes for cmux-only control socket requests.
public struct SocketClientAuthorization {
    /// Creates an authorization helper with no retained process state.
    public init() {}

    /// Returns whether a peer process is allowed to use cmux-only socket operations.
    ///
    /// A non-nil `peerProcessID` must resolve as a descendant of the trusted cmux
    /// process tree. A nil PID fails closed because the caller cannot be tied to
    /// a concrete process. `peerHasSameUID` is supplied by the socket handshake
    /// for callers that need it, but this check intentionally relies on ancestry.
    ///
    /// - Parameters:
    ///   - peerProcessID: The PID reported by the accepted socket, or nil when
    ///     the platform cannot provide one.
    ///   - peerHasSameUID: Whether the peer process has the same user ID as cmux.
    ///   - isDescendant: Predicate that verifies the PID belongs to the trusted
    ///     cmux process tree.
    public func isCmuxOnlyClientAllowed(
        peerProcessID: pid_t?,
        peerHasSameUID _: Bool,
        isDescendant: (pid_t) -> Bool
    ) -> Bool {
        if let peerProcessID {
            return isDescendant(peerProcessID)
        }
        return false
    }
}
