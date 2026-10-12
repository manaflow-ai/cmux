import Foundation

/// Decides how each hub startup retry enrolls this Mac and how long it waits.
///
/// Every enrollment is a `POST /api/vm/tunnel` that takes this Mac's access
/// lease on the server. Builds and tunnel roles on one Mac share that lease,
/// so a retry that asks again too soon only meets `409 vm_access_grant_busy`
/// and keeps the lease contended for everyone else.
///
/// - A started hub that failed may hold a config the network rejects, so the
///   next attempt replaces it with a fresh enrollment, once per recovery.
///   Later attempts reuse the config that enrollment wrote.
/// - A rejected enrollment request wrote nothing. A rejected replacement is
///   asked for again; an ordinary one stays ordinary rather than turning
///   into a forced replacement.
/// - A retryable answer's `retryAfterSeconds` sets the minimum wait.
struct CloudWireGuardHubRecoveryPlan: Sendable {
    /// Whether the next attempt replaces the written enrollment.
    private(set) var refreshesNextEnrollment = false
    private var replacedEnrollment = false

    /// Records a failed attempt and returns the wait before the next one.
    ///
    /// - Parameters:
    ///   - error: Why the attempt failed.
    ///   - backoff: The local backoff for this attempt.
    /// - Returns: The longer of `backoff` and the server's requested wait.
    mutating func recordFailure(_ error: Error, backoff: Duration) -> Duration {
        let clientError = error as? VMClientError
        // A failure after the enrollment request answered proves the
        // replacement config was written.
        if refreshesNextEnrollment, clientError == nil { replacedEnrollment = true }
        refreshesNextEnrollment = !replacedEnrollment && (clientError == nil || refreshesNextEnrollment)
        guard let serverWait = clientError?.serverRetryAfter else { return backoff }
        return max(backoff, serverWait)
    }
}
