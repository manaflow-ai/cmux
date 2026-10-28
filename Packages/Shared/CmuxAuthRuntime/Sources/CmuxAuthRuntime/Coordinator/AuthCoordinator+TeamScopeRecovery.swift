import Foundation

extension AuthCoordinator {
    /// Backoff before recovery attempt `attempt` (zero-based): 2s, doubling, capped at 60s.
    static func teamScopeRecoveryDelay(afterAttempt attempt: Int) -> Duration {
        .seconds(min(2 << min(max(attempt, 0), 5), 60))
    }

    /// Fast backoff sleeps per failure streak (2+4+8+16+32+60+60+60 s,
    /// about 4 minutes). After the last one the loop retries every
    /// ``teamScopeRecoveryMaximumDelay``, so a Mac that stays offline or a
    /// server that keeps failing costs one wake per 15 minutes.
    static let teamScopeRecoveryAttemptLimit = 8

    /// The capped backoff after the fast streak. It is not shorter than the
    /// longest 429 delay (``teamScopeRateLimitDelay(retryAfter:streak:jitter:)``
    /// clamps to 15 min), so the timer never checks inside a 429 window.
    static let teamScopeRecoveryMaximumDelay: Duration = .seconds(15 * 60)

    /// Whether a team-scope recovery loop is scheduled or backing off.
    public var hasPendingTeamScopeRecovery: Bool { teamScopeRecovery != nil }

    /// Retries now when the session is signed in without a loaded team list.
    ///
    /// Hosts call this on signals that make a retry likely to succeed (system
    /// wake, app activation). It is a no-op for a healthy session, so frequent
    /// signals cost nothing. A fast backoff keeps running in case this
    /// attempt also fails; a loop at the capped backoff starts a new fast one.
    public func recoverTeamScopeIfNeeded() async {
        // Until the last 429 delay has passed, an activation or wake must not
        // add a check; the backoff loop owns the next one.
        guard needsTeamScopeRecovery, teamScopeRateLimitRemaining() == .zero else { return }
        await checkExistingSession()
        guard teamScopeRecoveryIsAtMaximumBackoff, needsTeamScopeRecovery else { return }
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
    /// The fast backoff is bounded by ``teamScopeRecoveryAttemptLimit``.
    /// Then the loop retries every ``teamScopeRecoveryMaximumDelay``; a
    /// restored network path (``AuthNetworkRestorations``) ends that wait
    /// early, once any 429 delay has passed, and starts a new fast streak.
    func scheduleTeamScopeRecoveryIfNeeded() {
        guard needsTeamScopeRecovery, teamScopeRecovery == nil else { return }
        let id = UUID()
        let clock = self.clock
        let networkRestorations = self.networkRestorations
        teamScopeRecoveryIsAtMaximumBackoff = false
        let task = Task { @MainActor [weak self] in
            var attempt = 0
            // wakeup-allow: backoff teamScopeRecoveryAttemptLimit fast sleeps per streak, then one per 15 min
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
                    let rateLimitRemaining = self?.teamScopeRateLimitRemaining() ?? .zero
                    self?.setTeamScopeRecoveryAtMaximumBackoff(true, id: id)
                    let wake: TeamScopeRecoveryWake
                    do {
                        wake = try await clock.waitAtMaximumTeamScopeBackoff(
                            maximum: max(Self.teamScopeRecoveryMaximumDelay, rateLimitRemaining),
                            notBefore: rateLimitRemaining,
                            restorations: networkRestorations
                        )
                    } catch {
                        return
                    }
                    if wake == .networkRestored {
                        self?.setTeamScopeRecoveryAtMaximumBackoff(false, id: id)
                        attempt = 0
                    }
                }
                guard let self, self.teamScopeRecovery?.id == id, self.needsTeamScopeRecovery else { break }
                await self.checkExistingSession()
            }
            if self?.teamScopeRecovery?.id == id {
                self?.teamScopeRecovery = nil
                self?.teamScopeRecoveryIsAtMaximumBackoff = false
            }
        }
        teamScopeRecovery = (id, task)
    }

    private func setTeamScopeRecoveryAtMaximumBackoff(_ atMaximum: Bool, id: UUID) {
        guard teamScopeRecovery?.id == id else { return }
        teamScopeRecoveryIsAtMaximumBackoff = atMaximum
    }

    func cancelTeamScopeRecovery() {
        teamScopeRecovery?.task.cancel()
        teamScopeRecovery = nil
        teamScopeRecoveryIsAtMaximumBackoff = false
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
            teamScopeRateLimit = (streak, delay, clock.authErasedNow)
            rateLimitTelemetry.rateLimited(.sessionCheck, rateLimit: rateLimit, backoff: delay, attempt: streak)
        } else {
            teamScopeRateLimit = nil
        }
    }

    /// What is left of the last 429 delay, measured from when the 429 came;
    /// zero when there is none.
    func teamScopeRateLimitRemaining() -> Duration {
        guard let rateLimit = teamScopeRateLimit else { return .zero }
        // An instant from another clock cannot be measured: wait the whole delay.
        let elapsed = clock.authElapsed(since: rateLimit.since) ?? .zero
        return max(.zero, rateLimit.delay - elapsed)
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
