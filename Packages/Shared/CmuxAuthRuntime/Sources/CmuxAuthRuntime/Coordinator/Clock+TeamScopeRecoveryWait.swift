import Foundation

/// How a wait at the maximum team-scope backoff ended.
enum TeamScopeRecoveryWake: Sendable, Equatable {
    /// The capped backoff ran out.
    case timer
    /// The network path came back, and any 429 delay has run out.
    case networkRestored
}

extension Clock where Duration == Swift.Duration {
    /// The current instant, erased so the coordinator can keep it beside its `any Clock`.
    var authErasedNow: any InstantProtocol<Swift.Duration> { now }

    /// The time since `instant`, or `nil` when `instant` came from another clock.
    func authElapsed(since instant: any InstantProtocol<Swift.Duration>) -> Duration? {
        guard let instant = instant as? Instant else { return nil }
        return instant.duration(to: now)
    }

    /// Waits `maximum`, or until the network path comes back and `notBefore` has passed, whichever is first.
    ///
    /// Chromium's sync scheduler keeps retrying at the capped delay of its `BackoffDelayProvider`
    /// (`components/sync/engine/backoff_delay_provider.cc`) and retries early when `NetworkChangeNotifier`
    /// reports the connection back (`SyncSchedulerImpl::OnConnectionStatusChange`,
    /// `components/sync/engine/sync_scheduler_impl.cc`).
    func waitAtMaximumTeamScopeBackoff(
        maximum: Duration,
        notBefore: Duration,
        restorations: any AuthNetworkRestorations
    ) async throws -> TeamScopeRecoveryWake {
        let start = now
        return try await withThrowingTaskGroup(of: TeamScopeRecoveryWake.self) { group in
            group.addTask {
                // wakeup-allow: backoff the capped team-scope retry, at most one wake per 15 min
                try await self.sleep(until: start.advanced(by: maximum), tolerance: maximum.authWakeLeeway)
                return .timer
            }
            group.addTask {
                await restorations.waitForRestoration()
                try Task.checkCancellation()
                if notBefore > .zero {
                    // wakeup-allow: backoff the rest of a 429 delay before the check a restored path starts
                    try await self.sleep(until: start.advanced(by: notBefore), tolerance: notBefore.authWakeLeeway)
                }
                return .networkRestored
            }
            defer { group.cancelAll() }
            guard let wake = try await group.next() else { throw CancellationError() }
            return wake
        }
    }
}
