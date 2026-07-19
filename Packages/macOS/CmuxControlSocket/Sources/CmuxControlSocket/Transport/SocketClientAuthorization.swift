public import Darwin
public import CmuxSettings

/// Authorizes peer processes for control socket requests.
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

    /// Returns the command and authority carried by an authorized cmux-only request.
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
    /// - Returns: The authorization result when authorized, otherwise `nil`.
    public func authorizedCommandResult(
        _ command: String,
        peerProcessID: pid_t?,
        peerHasSameUID: Bool,
        capabilityAuthority: SocketClientCapabilityAuthority,
        isDescendant: (pid_t) -> Bool
    ) -> SocketClientAuthorizationResult? {
        let envelope = SocketClientCapabilityCommand(command)
        if peerHasSameUID,
           let envelope,
           capabilityAuthority.verifies(envelope.capability) {
            return SocketClientAuthorizationResult(
                command: envelope.command,
                basis: .verifiedCapability
            )
        }
        if let peerProcessID, isDescendant(peerProcessID) {
            return SocketClientAuthorizationResult(
                command: envelope?.command ?? command,
                basis: .descendant
            )
        }
        return nil
    }

    /// Returns the command carried by an authorized cmux-only request.
    ///
    /// This compatibility API intentionally omits the authorization basis.
    /// Callers making policy decisions should use ``authorizedCommandResult(_:peerProcessID:peerHasSameUID:capabilityAuthority:isDescendant:)``.
    public func authorizedCommand(
        _ command: String,
        peerProcessID: pid_t?,
        peerHasSameUID: Bool,
        capabilityAuthority: SocketClientCapabilityAuthority,
        isDescendant: (pid_t) -> Bool
    ) -> String? {
        authorizedCommandResult(
            command,
            peerProcessID: peerProcessID,
            peerHasSameUID: peerHasSameUID,
            capabilityAuthority: capabilityAuthority,
            isDescendant: isDescendant
        )?.command
    }

    /// Applies the current socket access mode and records its authorization basis.
    ///
    /// Owner-only modes verify the peer UID for every command instead of
    /// relying solely on socket-file permissions. This keeps restrictive
    /// modes fail-closed if a permission change cannot be applied to the
    /// filesystem entry of an already running listener.
    public func authorizedCommandResult(
        _ command: String,
        accessMode: SocketControlMode,
        peerProcessID: pid_t?,
        peerHasSameUID: Bool,
        capabilityAuthority: SocketClientCapabilityAuthority,
        isDescendant: (pid_t) -> Bool
    ) -> SocketClientAuthorizationResult? {
        switch accessMode {
        case .off:
            return nil
        case .cmuxOnly:
            return authorizedCommandResult(
                command,
                peerProcessID: peerProcessID,
                peerHasSameUID: peerHasSameUID,
                capabilityAuthority: capabilityAuthority,
                isDescendant: isDescendant
            )
        case .automation, .password:
            guard peerHasSameUID else { return nil }
            return result(
                for: command,
                fallbackBasis: .sameOwner,
                capabilityAuthority: capabilityAuthority
            )
        case .allowAll:
            return result(
                for: command,
                fallbackBasis: .unrestricted,
                capabilityAuthority: capabilityAuthority
            )
        }
    }

    /// Applies the current socket access mode to a received command.
    ///
    /// This compatibility API intentionally omits the authorization basis.
    /// Callers making policy decisions should use ``authorizedCommandResult(_:accessMode:peerProcessID:peerHasSameUID:capabilityAuthority:isDescendant:)``.
    public func authorizedCommand(
        _ command: String,
        accessMode: SocketControlMode,
        peerProcessID: pid_t?,
        peerHasSameUID: Bool,
        capabilityAuthority: SocketClientCapabilityAuthority,
        isDescendant: (pid_t) -> Bool
    ) -> String? {
        authorizedCommandResult(
            command,
            accessMode: accessMode,
            peerProcessID: peerProcessID,
            peerHasSameUID: peerHasSameUID,
            capabilityAuthority: capabilityAuthority,
            isDescendant: isDescendant
        )?.command
    }

    private func result(
        for command: String,
        fallbackBasis: SocketClientAuthorizationBasis,
        capabilityAuthority: SocketClientCapabilityAuthority
    ) -> SocketClientAuthorizationResult {
        let envelope = SocketClientCapabilityCommand(command)
        let basis: SocketClientAuthorizationBasis = if let envelope,
                                                       capabilityAuthority.verifies(envelope.capability) {
            .verifiedCapability
        } else {
            fallbackBasis
        }
        return SocketClientAuthorizationResult(
            command: envelope?.command ?? command,
            basis: basis
        )
    }
}
