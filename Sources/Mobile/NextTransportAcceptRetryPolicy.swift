#if DEBUG
import Foundation

/// Bounded reconnect backoff for transient accept failures, not a polling loop.
struct NextTransportAcceptRetryPolicy {
    private var failures = 0

    mutating func reset() { failures = 0 }

    mutating func waitAfterFailure(
        sleep: @Sendable (Duration) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let delay = min(100 * (1 << failures), 5_000)
        failures = min(failures + 1, 6)
        try await sleep(.milliseconds(delay))
        try Task.checkCancellation()
    }
}
#endif
