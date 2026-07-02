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
///    actually serving (clean health *and* a ping the listener could only have
///    produced while alive); a probe that comes back empty/`nil` while the
///    in-memory health looks fine is the refused-socket signal that the flags
///    alone miss.
///
/// A live listener normally answers `ping` with `PONG`, but in password mode it
/// answers an *unauthenticated* `ping` with an auth-required challenge instead
/// (see `TerminalController.passwordAuthRequiredResponse`). That challenge is
/// equally proof the accept loop is alive and dispatching, so the policy treats
/// it as serving — otherwise every activation would tear down a healthy
/// password-protected listener and drop its connected clients.
///
/// Construct once at the composition root and inject; the interval is
/// configurable for tests.
public struct SocketListenerActivationRecoveryPolicy: Sendable {
    /// The expected reply to a `ping` probe from a live listener.
    public static let healthyPingResponse = "PONG"

    /// Substring present in the control socket's password auth-required
    /// response. A password-protected listener replies to an unauthenticated
    /// `ping` with this challenge rather than `PONG`, and receiving it still
    /// proves the accept loop is alive and dispatching commands.
    ///
    /// Source of truth: `TerminalController.passwordAuthRequiredResponse`, whose
    /// v1 and v2 responses are both built from this marker so the produced wire
    /// string always contains what this policy recognizes.
    public static let passwordAuthRequiredResponseMarker = "Authentication required"

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
    /// True only when the in-memory health is clean *and* the ping came back as
    /// a response the listener could only have produced while alive — either
    /// `PONG` or, in password mode, the auth-required challenge. A `nil`/empty
    /// ping means the socket path is present but not accepting connections — the
    /// refused-listener state this policy exists to detect.
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
        guard health.isHealthy, let pingResponse else { return false }
        return Self.pingResponseProvesListenerServing(pingResponse)
    }

    /// Whether a `ping` probe response proves the listener's accept loop is
    /// alive and dispatching commands.
    ///
    /// A live listener answers `ping` with `PONG`; a password-protected listener
    /// answers an unauthenticated `ping` with the auth-required challenge. Both
    /// prove the socket is accepting connections. A refused/dead listener yields
    /// no line (handled as `nil` by ``listenerIsServing(health:pingResponse:)``)
    /// or an empty line, neither of which matches here.
    ///
    /// - Parameter response: The first line returned by the `ping` probe.
    /// - Returns: True when the response could only come from a live listener.
    public static func pingResponseProvesListenerServing(_ response: String) -> Bool {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == healthyPingResponse { return true }
        return trimmed.contains(passwordAuthRequiredResponseMarker)
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
