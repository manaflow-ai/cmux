import Foundation

/// Captures an absolute deadline so a response scheduled ahead of the timer on
/// wake cannot publish credentials after its budget elapsed.
struct AuthTokenDeadline: Sendable {
    let hasExpired: @Sendable () -> Bool
    let remaining: @Sendable () -> Duration
    let wait: @Sendable () async throws -> Void
}
