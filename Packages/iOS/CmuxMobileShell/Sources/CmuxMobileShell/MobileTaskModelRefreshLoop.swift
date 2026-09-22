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
            try await Task.sleep(for: duration)
        }
    ) async {
        var attempt = 0
        // The composer contract requires recovery to continue for the entire
        // time it remains open. Only a typed permanent outcome or owner
        // cancellation may end this loop; the capped delay prevents a hot
        // request loop while the Mac or provider is unavailable.
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
