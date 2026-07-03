import Foundation

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
        return pingResponseProvesListenerServing(pingResponse)
    }

    /// Classifies a `ping` probe response into a bounded, telemetry-safe kind.
    ///
    /// - Parameter response: The first line returned by a `ping` probe, or `nil`
    ///   when the probe failed, timed out, or was skipped.
    /// - Returns: The coarse ``SocketListenerActivationPingResponseKind`` — never the raw text.
    public func pingResponseKind(_ response: String?) -> SocketListenerActivationPingResponseKind {
        guard let response else { return .missing }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed == Self.healthyPingResponse { return .pong }
        if trimmed.contains(Self.passwordAuthRequiredResponseMarker) { return .authChallenge }
        return .unexpected
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
    public func pingResponseProvesListenerServing(_ response: String) -> Bool {
        switch pingResponseKind(response) {
        case .pong, .authChallenge:
            return true
        case .missing, .empty, .unexpected:
            return false
        }
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

    /// Whether a rebind decision derived from a probe is still current.
    ///
    /// The `ping` probe blocks, so the host runs it off the main actor and only
    /// applies the resulting rebind on the main actor afterward. In that window
    /// any recovery path can replace the listener — a host-driven restart
    /// (`workspace.didWake`, a menu command, the ensure path) *or* the
    /// listener's own internal recovery (the path monitor's rearm, the accept
    /// source's rebind). The authoritative signal that covers all of them is
    /// the server's accept-loop generation (`SocketControlServer.activeListenerGeneration`),
    /// bumped on every (re)start regardless of who triggered it. The host
    /// captures it before the probe and passes it here alongside the current
    /// value: a mismatch means the probed listener was already replaced, so the
    /// stale decision must be discarded rather than tearing down the fresh
    /// listener and dropping its clients (#6406 review, activation/wake race).
    ///
    /// - Parameters:
    ///   - capturedGeneration: Accept-loop generation sampled with the probe.
    ///   - currentGeneration: Accept-loop generation now, on the main actor.
    /// - Returns: True when no rebind happened meanwhile and the decision holds.
    public func rebindDecisionIsCurrent(capturedGeneration: UInt64, currentGeneration: UInt64) -> Bool {
        capturedGeneration == currentGeneration
    }

    /// Whether the activation heal may act on its rebind decision now.
    ///
    /// Three independent conditions must all hold before the heal tears down and
    /// rebinds the listener:
    ///
    /// 1. The decision is still current — the accept-loop generation has not
    ///    moved since the probe (see
    ///    ``rebindDecisionIsCurrent(capturedGeneration:currentGeneration:)``);
    ///    otherwise the probed listener was already replaced.
    /// 2. The server is not already recovering the accept loop on its own. On an
    ///    accept failure the listener backs off deliberately — a delayed rearm or
    ///    a suspended accept source — and both windows read like the refused
    ///    socket this policy heals while leaving the generation unchanged.
    ///    Rebinding then would cancel the scheduled recovery and reset the
    ///    accept-failure streak, defeating the backoff under sustained resource
    ///    pressure (e.g. `EMFILE`). The heal exists only for the case where
    ///    *nothing* re-arms recovery (#6406), so it defers whenever the server
    ///    reports recovery pending (`SocketControlServer.hasPendingAcceptRecovery`).
    /// 3. The app is not tearing down. The `ping` probe runs off the main actor,
    ///    so app termination or an updater relaunch can call
    ///    `TerminalController.stop()` while it is in flight, resetting the
    ///    accept-loop generation to 0 on purpose. A probe that captured 0 (or
    ///    finished after the reset) would otherwise see `0 == 0`, pass the
    ///    currency check with no recovery pending, and resurrect the very socket
    ///    the termination path just stopped. Gating on `isTerminating` keeps the
    ///    heal from recreating the listener after teardown (#6406 review,
    ///    teardown race).
    ///
    /// - Parameters:
    ///   - capturedGeneration: Accept-loop generation sampled with the probe.
    ///   - currentGeneration: Accept-loop generation now, on the main actor.
    ///   - serverRecoveryPending: Whether the server has a delayed accept
    ///     recovery (parked rearm or suspended accept source) in progress.
    ///   - isTerminating: Whether the app has begun terminating (quit or updater
    ///     relaunch). When true the listener is being stopped deliberately, so
    ///     the heal must never rebind.
    /// - Returns: True only when the decision is current, no server recovery is
    ///   pending, and the app is not terminating, so the rebind may proceed.
    public func rebindShouldProceed(
        capturedGeneration: UInt64,
        currentGeneration: UInt64,
        serverRecoveryPending: Bool,
        isTerminating: Bool
    ) -> Bool {
        guard !isTerminating else { return false }
        return rebindDecisionIsCurrent(capturedGeneration: capturedGeneration, currentGeneration: currentGeneration)
            && !serverRecoveryPending
    }
}
