import Foundation

extension AuthCoordinator {
    /// Whether a team-scope recovery loop is scheduled.
    public var hasPendingTeamScopeRecovery: Bool { snapshot.hasPendingTeamScopeRecovery }

    /// Retries now when the session is signed in without a loaded team list.
    ///
    /// Hosts call this on signals that make a retry likely to succeed (network
    /// path restored, system wake, app activation). It is a no-op for a
    /// healthy session, and while the sign-in service says too many requests
    /// (the backoff loop owns the next check then).
    public func recoverTeamScopeIfNeeded() async {
        await restore("teamScopeSignal")
    }

    /// Signed in, but the team list has not loaded for the current session
    /// and no fetch is in flight to load it. ``authenticatedTeamScope`` stays
    /// nil in this state, so every scope-gated service stays down.
    var needsTeamScopeRecovery: Bool { snapshot.needsTeamScopeRecovery }
}
