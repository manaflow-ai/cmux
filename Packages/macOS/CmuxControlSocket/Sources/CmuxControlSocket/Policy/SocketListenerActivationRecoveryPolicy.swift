/// Pure decision logic for self-healing the control-socket listener when the
/// app is reactivated.
///
/// The listener's in-memory ``SocketListenerHealth`` flags describe what the
/// app *believes* about the listener, but they can read healthy while the
/// socket file on disk is actually refusing connections — a recovery hop was
/// dropped, a stale socket survived a half-finished restart, or the listening
/// descriptor died without the state machine noticing
/// (https://github.com/manaflow-ai/cmux/issues/6406, errno 61 / `ECONNREFUSED`).
/// The path monitor cannot catch that case because the socket *file* still
/// exists, so nothing re-arms recovery while the app keeps running and the user
/// has to restart the app to get a live listener back.
///
/// This policy decides, with no I/O, two things the host combines with an
/// actual `ping`/`PONG` round-trip:
///
/// 1. ``shouldRunReadinessCheck(secondsSinceLastCheck:)`` — a throttle so the
///    probe runs at most once per ``minimumReadinessCheckIntervalSeconds``,
///    keeping rapid reactivations from hammering a listener that genuinely
///    cannot bind.
/// 2. ``shouldRebindListener(health:pingResponse:)`` — whether the listener is
///    actually serving (clean health *and* a `PONG`); a non-`PONG` ping while
///    the in-memory health looks fine is the refused-socket signal that the
///    flags alone miss.
///
/// Construct once at the composition root and inject; the interval is
/// configurable for tests.
public struct SocketListenerActivationRecoveryPolicy: Sendable {
    /// The expected reply to a `ping` probe from a live listener.
    public static let healthyPingResponse = "PONG"

    /// Minimum seconds between activation readiness checks. Bounds how often a
    /// blocking ping probe (and any resulting rebind) runs across reactivations.
    public let minimumReadinessCheckIntervalSeconds: Double

    /// Creates a policy.
    ///
    /// - Parameter minimumReadinessCheckIntervalSeconds: Throttle interval
    ///   between activation readiness checks (default 15s).
    public init(minimumReadinessCheckIntervalSeconds: Double = 15) {
        self.minimumReadinessCheckIntervalSeconds = minimumReadinessCheckIntervalSeconds
    }

    /// Whether enough time has elapsed to run another activation readiness
    /// check.
    ///
    /// - Parameter secondsSinceLastCheck: Seconds since the last check, or `nil`
    ///   when no check has run yet (always allowed).
    /// - Returns: True when the readiness check (ping probe) may run now.
    public func shouldRunReadinessCheck(secondsSinceLastCheck: Double?) -> Bool {
        guard let secondsSinceLastCheck else { return true }
        return secondsSinceLastCheck >= minimumReadinessCheckIntervalSeconds
    }

    /// Whether the listener is actually serving connections.
    ///
    /// True only when the in-memory health is clean *and* a ping returned the
    /// healthy response. A `nil` or non-`PONG` ping means the socket path is
    /// present but not accepting — the refused-listener state this policy
    /// exists to detect.
    ///
    /// - Parameters:
    ///   - health: The listener's in-memory health snapshot.
    ///   - pingResponse: The first line returned by a `ping` probe, or `nil`
    ///     when the probe failed, timed out, or was skipped.
    /// - Returns: True when the listener is healthy and answered the ping.
    public func listenerIsServing(
        health: SocketListenerHealth,
        pingResponse: String?
    ) -> Bool {
        health.isHealthy && pingResponse == Self.healthyPingResponse
    }

    /// Whether the listener should be torn down and rebound after a readiness
    /// check produced `health`/`pingResponse`. The inverse of
    /// ``listenerIsServing(health:pingResponse:)``.
    ///
    /// - Parameters:
    ///   - health: The listener's in-memory health snapshot.
    ///   - pingResponse: The first line returned by a `ping` probe, or `nil`.
    /// - Returns: True when the listener is not serving and a rebind is needed.
    public func shouldRebindListener(
        health: SocketListenerHealth,
        pingResponse: String?
    ) -> Bool {
        !listenerIsServing(health: health, pingResponse: pingResponse)
    }
}
