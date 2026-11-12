import Foundation

/// Decides how each hub startup retry enrolls this Mac and how long it waits.
///
/// Every enrollment is a `POST /api/vm/tunnel` that takes this Mac's access
/// lease on the server. Builds and tunnel roles on one Mac share that lease,
/// so a retry that asks again too soon only meets `409 vm_access_grant_busy`
/// and keeps the lease contended for everyone else.
///
/// - A hub that failed after enrolling may hold a config the network rejects, so the
///   next attempt replaces it with a fresh enrollment, once per recovery.
///   Later attempts reuse the config that enrollment wrote.
/// - A rejected enrollment request wrote nothing. A rejected replacement is
///   asked for again; an ordinary one stays ordinary rather than turning
///   into a forced replacement.
/// - A retryable answer's `retryAfterSeconds` sets the minimum wait.
/// - `409 vm_access_grant_busy` means another build or tunnel role on this
///   Mac is enrolling. It waits as the server asks without spending a restart
///   attempt, within ``busyBudget``, so a first connection succeeds once the
///   lease frees instead of failing after a few seconds.
struct CloudWireGuardHubRecoveryPlan: Sendable {
    /// The longest total wait for this Mac's access lease in one recovery.
    static let busyBudget: Duration = .seconds(90)

    /// Whether the next attempt replaces the written enrollment.
    private(set) var refreshesNextEnrollment = false
    private var replacedEnrollment = false
    private var busyWaited: Duration = .zero
    private let backoff: [Duration]
    private var restarts = 0

    /// - Parameter backoff: The local wait before each restart attempt; its
    ///   length bounds the attempts that are not a busy lease.
    init(backoff: [Duration] = []) {
        self.backoff = backoff
    }

    /// Records a failed attempt and returns the wait before the next one, or
    /// nil when recovery should give up with `error`.
    ///
    /// - Parameters:
    ///   - error: Why the attempt failed.
    ///   - enrolled: Whether the attempt's enrollment step finished.
    mutating func wait(after error: Error, enrolled: Bool) -> Duration? {
        // Another request holds this Mac's access lease: progress elsewhere,
        // not a failure, so it does not spend a restart attempt.
        if !enrolled, Self.isBusyLease(error) { return busyWait(after: error) }
        guard restarts < backoff.count else { return nil }
        defer { restarts += 1 }
        return recordFailure(error, enrolled: enrolled, backoff: backoff[restarts])
    }

    /// The wait before asking again when `error` is the lease-busy answer and
    /// the busy budget allows it; nil otherwise.
    /// A busy lease whose budget is spent gives up rather than turning into
    /// ordinary restarts that would wait the server's delay again each time.
    mutating func busyWait(after error: Error) -> Duration? {
        guard Self.isBusyLease(error), let clientError = error as? VMClientError else { return nil }
        let wait = max(clientError.serverRetryAfter ?? .seconds(1), .seconds(1))
        guard busyWaited + wait <= Self.busyBudget else { return nil }
        busyWaited += wait
        // A refused request wrote nothing; keep the replacement decision.
        _ = recordFailure(error, enrolled: false, backoff: .zero)
        return wait
    }

    static func isBusyLease(_ error: Error) -> Bool {
        guard let clientError = error as? VMClientError, case .httpStatus(409, _) = clientError else { return false }
        return clientError.serverErrorCode == "vm_access_grant_busy"
    }

    /// Records a failed attempt and returns the wait before the next one.
    ///
    /// - Parameters:
    ///   - error: Why the attempt failed.
    ///   - enrolled: Whether the attempt's enrollment step finished, so the
    ///     failure came from the hub that used it.
    ///   - backoff: The local backoff for this attempt.
    /// - Returns: The longer of `backoff` and the server's requested wait.
    mutating func recordFailure(_ error: Error, enrolled: Bool, backoff: Duration) -> Duration {
        // A hub that failed after a replacement enrolled proves the
        // replacement config was written; one more would only contend.
        if refreshesNextEnrollment, enrolled { replacedEnrollment = true }
        // A hub failure suspects the written config. A failed enrollment step
        // keeps the decision it was made under.
        refreshesNextEnrollment = !replacedEnrollment && (enrolled || refreshesNextEnrollment)
        guard let serverWait = (error as? VMClientError)?.serverRetryAfter else { return backoff }
        return max(backoff, serverWait)
    }
}
