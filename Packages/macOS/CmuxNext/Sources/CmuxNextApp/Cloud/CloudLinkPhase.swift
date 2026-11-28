// Phases a Cloud machine stage is derived from (cx-lu8f, CloudMachineStage).

/// The link from this Mac to a Cloud machine's daemon, as the session sees
/// its endpoint calls (`CloudMachineSession.linkPhase`).
nonisolated enum CloudLinkPhase: Hashable, Sendable {
    /// No connect was asked for (or the link was parked or stopped).
    case idle
    /// The link is starting: attach endpoint, tunnel, remote connect.
    case starting
    /// The link socket answered: the daemon connection can start.
    case up
    /// The last start failed with this text; a later start that succeeds
    /// clears it (the daemon retries by itself).
    case failed(String)
}

/// A machine creation's request, before its session exists.
nonisolated enum CloudCreationPhase: Hashable, Sendable {
    /// Getting the sign-in token and team.
    case requesting
    /// `POST /api/vm` sent; waiting for the server.
    case creating
    /// The server returned the machine (its session takes over).
    case created
    case failed(String)
}
