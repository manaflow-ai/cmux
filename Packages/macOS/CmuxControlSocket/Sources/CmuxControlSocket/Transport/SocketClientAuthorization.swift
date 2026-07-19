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

    /// Returns the command carried by an authorized cmux-only request.
    ///
    /// Descendants retain the existing process-tree authorization. The
    /// capability parameters form the runtime seam for terminals whose
    /// process trees are later reparented by a multiplexer.
    ///
    /// - Parameters:
    ///   - command: The raw command line received from the client.
    ///   - peerProcessID: The PID reported by the accepted socket.
    ///   - peerHasSameUID: Whether the peer runs as the same user as cmux.
    ///   - capabilityAuthority: The authority that verifies inherited tokens.
    ///   - isDescendant: Predicate that verifies current process ancestry.
    /// - Returns: The unwrapped command when authorized, otherwise `nil`.
    public func authorizedCommand(
        _ command: String,
        peerProcessID: pid_t?,
        peerHasSameUID: Bool,
        capabilityAuthority: SocketClientCapabilityAuthority,
        isDescendant: (pid_t) -> Bool
    ) -> String? {
        let envelope = SocketClientCapabilityCommand(command)
        if let peerProcessID, isDescendant(peerProcessID) {
            return envelope?.command ?? command
        }
        guard peerHasSameUID,
              let envelope,
              capabilityAuthority.verifies(envelope.capability) else {
            return nil
        }
        return envelope.command
    }
}
