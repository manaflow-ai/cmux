import Foundation

extension AuthCoordinator {
    /// Backoff before recovery attempt `attempt` (zero-based): 2s, doubling, capped at 60s.
    static func teamScopeRecoveryDelay(afterAttempt attempt: Int) -> Duration {
        .seconds(min(2 << min(max(attempt, 0), 5), 60))
    }

    /// Whether a team-scope recovery loop is scheduled.
    var hasPendingTeamScopeRecovery: Bool { teamScopeRecovery != nil }

    /// Signed in, but the team list has not loaded for the current session.
    ///
    /// ``authenticatedTeamScope`` stays nil in this state, so every
    /// scope-gated service (the iOS pairing host, Cloud) stays down.
    var needsTeamScopeRecovery: Bool {
        isAuthenticated && authenticatedTeamsSessionGeneration != sessionGeneration
    }

    /// Starts the single retry loop that revalidates the session until the
    /// team list loads or the session ends.
    ///
    /// Launch restore and sign-in tolerate a failed team fetch or a transient
    /// validation failure and keep the cached session. iOS repairs that on its
    /// next foreground revalidation; macOS has no such trigger, so without
    /// this loop the state lasts until the app restarts. A definitive session
    /// rejection during a retry routes to sign-in through the normal
    /// validation path, which also ends the loop.
    func scheduleTeamScopeRecoveryIfNeeded() {
        guard needsTeamScopeRecovery, teamScopeRecovery == nil else { return }
        let id = UUID()
        let clock = self.clock
        let task = Task { @MainActor [weak self] in
            var attempt = 0
            while true {
                do {
                    try await clock.sleep(for: Self.teamScopeRecoveryDelay(afterAttempt: attempt), tolerance: nil)
                } catch {
                    return
                }
                guard let self, self.teamScopeRecovery?.id == id, self.needsTeamScopeRecovery else { break }
                attempt += 1
                await self.checkExistingSession()
            }
            if self?.teamScopeRecovery?.id == id {
                self?.teamScopeRecovery = nil
            }
        }
        teamScopeRecovery = (id, task)
    }

    func cancelTeamScopeRecovery() {
        teamScopeRecovery?.task.cancel()
        teamScopeRecovery = nil
    }
}
