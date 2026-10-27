import Foundation

extension AuthCoordinator {
    /// Backoff before recovery attempt `attempt` (zero-based): 2s, doubling, capped at 60s.
    static func teamScopeRecoveryDelay(afterAttempt attempt: Int) -> Duration {
        .seconds(min(2 << min(max(attempt, 0), 5), 60))
    }

    /// Backoff sleeps per failure streak (2+4+8+16+32+60+60+60 s, about
    /// 4 minutes). After the last one the loop parks until the network path
    /// comes back or a host trigger, so an offline Mac takes no timer wakes.
    static let teamScopeRecoveryAttemptLimit = 8

    /// Whether a team-scope recovery loop is scheduled, backing off or parked.
    public var hasPendingTeamScopeRecovery: Bool { teamScopeRecovery != nil }

    /// Retries now when the session is signed in without a loaded team list.
    ///
    /// Hosts call this on signals that make a retry likely to succeed (system
    /// wake, app activation). It is a no-op for a healthy session, so frequent
    /// signals cost nothing. A running backoff keeps running in case this
    /// attempt also fails; a parked loop starts a new backoff.
    public func recoverTeamScopeIfNeeded() async {
        // While the sign-in service says too many requests, an activation or
        // wake must not add a check; the backoff loop owns the next one. A
        // parked loop has already waited out the last 429 delay.
        guard needsTeamScopeRecovery, teamScopeRateLimit == nil || teamScopeRecoveryIsParked else { return }
        await checkExistingSession()
        guard teamScopeRecoveryIsParked, needsTeamScopeRecovery else { return }
        teamScopeRecovery?.task.cancel()
        teamScopeRecovery = nil
        scheduleTeamScopeRecoveryIfNeeded()
    }

    /// Signed in, but the team list has not loaded for the current session
    /// and no fetch is in flight to load it.
    ///
    /// ``authenticatedTeamScope`` stays nil in this state, so every
    /// scope-gated service (the iOS pairing host, Cloud) stays down.
    var needsTeamScopeRecovery: Bool {
        isAuthenticated
            && activeTeamRefreshCount == 0
            && authenticatedTeamsSessionGeneration != sessionGeneration
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
    ///
    /// The backoff is bounded by ``teamScopeRecoveryAttemptLimit``. Then the
    /// loop parks on ``AuthNetworkRestorations`` with no timer, and a
    /// restored path starts a new streak with an immediate check.
    func scheduleTeamScopeRecoveryIfNeeded() {
        guard needsTeamScopeRecovery, teamScopeRecovery == nil else { return }
        let id = UUID()
        let clock = self.clock
        let networkRestorations = self.networkRestorations
        teamScopeRecoveryIsParked = false
        let task = Task { @MainActor [weak self] in
            var attempt = 0
            // wakeup-allow: backoff at most teamScopeRecoveryAttemptLimit sleeps per streak, then parked on a network restoration
            while true {
                if attempt < Self.teamScopeRecoveryAttemptLimit {
                    do {
                        let delay = self?.teamScopeRecoveryWait(afterAttempt: attempt)
                            ?? Self.teamScopeRecoveryDelay(afterAttempt: attempt)
                        // wakeup-allow: backoff 2 s doubling to 60 s, or the 429 wait, after a failed team fetch
                        try await clock.sleep(for: delay, tolerance: delay.authWakeLeeway)
                    } catch {
                        return
                    }
                    attempt += 1
                } else {
                    self?.setTeamScopeRecoveryParked(true, id: id)
                    await networkRestorations.waitForRestoration()
                    if Task.isCancelled { return }
                    self?.setTeamScopeRecoveryParked(false, id: id)
                    attempt = 0
                }
                guard let self, self.teamScopeRecovery?.id == id, self.needsTeamScopeRecovery else { break }
                await self.checkExistingSession()
            }
            if self?.teamScopeRecovery?.id == id {
                self?.teamScopeRecovery = nil
                self?.teamScopeRecoveryIsParked = false
            }
        }
        teamScopeRecovery = (id, task)
    }

    private func setTeamScopeRecoveryParked(_ parked: Bool, id: UUID) {
        guard teamScopeRecovery?.id == id else { return }
        teamScopeRecoveryIsParked = parked
    }

    func cancelTeamScopeRecovery() {
        teamScopeRecovery?.task.cancel()
        teamScopeRecovery = nil
        teamScopeRecoveryIsParked = false
        teamScopeRateLimit = nil
    }

    /// Records why a user fetch or team load failed: a 429 starts or extends
    /// the rate-limit backoff, any other classified failure ends it. A
    /// timeout or token-probe failure leaves it unchanged, so a 429 followed
    /// by a timeout keeps the longer wait.
    func noteTeamScopeFailure(_ error: any Error) {
        if let rateLimit = AuthRateLimit(error: error) {
            let streak = (teamScopeRateLimit?.streak ?? 0) + 1
            let delay = Self.teamScopeRateLimitDelay(
                retryAfter: rateLimit.retryAfter,
                streak: streak,
                jitter: Double.random(in: 0.5...1.0)
            )
            teamScopeRateLimit = (streak, delay)
            rateLimitTelemetry.rateLimited(.sessionCheck, rateLimit: rateLimit, backoff: delay, attempt: streak)
        } else {
            teamScopeRateLimit = nil
        }
    }

    /// The wait before the next recovery check: the normal backoff, or,
    /// after a 429, `Retry-After` (clamped to 1 s-15 min, then stretched by
    /// up to 50% so Macs behind one IP do not wake together) or 30 s
    /// doubling to 15 min with jitter.
    func teamScopeRecoveryWait(afterAttempt attempt: Int) -> Duration {
        let normal = Self.teamScopeRecoveryDelay(afterAttempt: attempt)
        guard let rateLimit = teamScopeRateLimit else { return normal }
        // The jittered delay is drawn once per 429, so the reported backoff
        // is the wait the loop actually takes.
        return max(normal, rateLimit.delay)
    }

    static func teamScopeRateLimitDelay(retryAfter: Duration?, streak: Int, jitter: Double) -> Duration {
        let ceiling: Duration = .seconds(15 * 60)
        let spread = min(max(jitter, 0.5), 1.0)
        if let retryAfter {
            let base = min(max(retryAfter, .seconds(1)), ceiling)
            // Never earlier than Retry-After; spread the wake-ups above it.
            return min(base * (0.5 + spread), ceiling)
        }
        let exponent = Double(max(0, min(streak - 1, 5)))
        let seconds = min(30 * pow(2, exponent), 900) * spread
        return .milliseconds(Int64(seconds * 1000))
    }
}
