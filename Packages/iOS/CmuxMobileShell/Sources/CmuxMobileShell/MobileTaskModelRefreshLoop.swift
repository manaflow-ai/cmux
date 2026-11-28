import Foundation

/// Repeats task model discovery while its owner remains interested.
public struct MobileTaskModelRefreshLoop: Sendable {
    /// Creates a refresh loop.
    public init() {}

    /// Returns the capped exponential delay before the given retry attempt.
    public func delay(for attempt: Int) -> Duration {
        let shift = min(max(attempt, 0), 5)
        let milliseconds = min(15_000, 500 * (1 << shift))
        return .milliseconds(milliseconds)
    }

    /// Runs discovery until it succeeds, is explicitly non-retryable, or its
    /// owner cancels. The capped delay avoids a tight request loop during a
    /// long outage while the composer remains open for recovery.
    @MainActor
    public func run(
        shouldContinue: @escaping @MainActor () -> Bool = { true },
        refresh: @escaping @MainActor () async -> MobileTaskModelRefreshOutcome,
        sleep: @escaping @MainActor (Duration) async throws -> Void = { duration in
            // Model discovery has no host push signal, so the composer owns a
            // bounded polling delay while it remains open. ContinuousClock
            // keeps this wait monotonic; tests inject an immediate clock.
            try await ContinuousClock().sleep(for: duration)
        }
    ) async {
        var attempt = 0
        // Do not add an attempt or deadline cap here. The composer contract
        // requires recovery to continue for the entire time it remains open;
        // only the owner cancellation check or a typed permanent outcome may
        // end this loop. The capped delay is the request-rate bound while the
        // Mac or provider is unavailable.
        while !Task.isCancelled, shouldContinue() {
            switch await refresh() {
            case .succeeded, .stopped:
                return
            case .retry:
                let delay = self.delay(for: attempt)
                attempt += 1
                do {
                    try await sleep(delay)
                } catch {
                    return
                }
            }
        }
    }
}
