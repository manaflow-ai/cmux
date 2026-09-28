import Foundation

extension AuthCoordinator {
    /// Backoff before recovery attempt `attempt` (zero-based): 2s, doubling, capped at 60s.
    static func teamScopeRecoveryDelay(afterAttempt attempt: Int) -> Duration {
        .seconds(min(2 << min(max(attempt, 0), 5), 60))
    }

    /// Whether a team-scope recovery loop is scheduled.
    var hasPendingTeamScopeRecovery: Bool { false }
}
