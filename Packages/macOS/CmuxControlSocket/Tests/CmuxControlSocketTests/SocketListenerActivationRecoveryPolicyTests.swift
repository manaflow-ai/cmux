import Testing

@testable import CmuxControlSocket

@Suite struct SocketListenerActivationRecoveryPolicyTests {
    private static let healthy = SocketListenerHealth(
        isRunning: true,
        acceptLoopAlive: true,
        socketPathMatches: true,
        socketPathExists: true,
        socketPathOwnedByListener: true
    )

    private static let down = SocketListenerHealth(
        isRunning: false,
        acceptLoopAlive: false,
        socketPathMatches: true,
        socketPathExists: true,
        socketPathOwnedByListener: true
    )

    // MARK: - Throttle

    @Test func readinessCheckRunsWhenNeverCheckedBefore() {
        let policy = SocketListenerActivationRecoveryPolicy(minimumReadinessCheckIntervalSeconds: 15)
        #expect(policy.shouldRunReadinessCheck(secondsSinceLastCheck: nil))
    }

    @Test func readinessCheckIsThrottledWithinTheInterval() {
        let policy = SocketListenerActivationRecoveryPolicy(minimumReadinessCheckIntervalSeconds: 15)
        #expect(!policy.shouldRunReadinessCheck(secondsSinceLastCheck: 0))
        #expect(!policy.shouldRunReadinessCheck(secondsSinceLastCheck: 14.999))
    }

    @Test func readinessCheckRunsOnceTheIntervalElapses() {
        let policy = SocketListenerActivationRecoveryPolicy(minimumReadinessCheckIntervalSeconds: 15)
        #expect(policy.shouldRunReadinessCheck(secondsSinceLastCheck: 15))
        #expect(policy.shouldRunReadinessCheck(secondsSinceLastCheck: 60))
    }

    @Test func customIntervalIsHonored() {
        let policy = SocketListenerActivationRecoveryPolicy(minimumReadinessCheckIntervalSeconds: 1)
        #expect(!policy.shouldRunReadinessCheck(secondsSinceLastCheck: 0.5))
        #expect(policy.shouldRunReadinessCheck(secondsSinceLastCheck: 1))
    }

    // MARK: - Readiness / rebind decision

    @Test func healthyListenerThatAnswersPingIsServing() {
        let policy = SocketListenerActivationRecoveryPolicy()
        #expect(policy.listenerIsServing(health: Self.healthy, pingResponse: "PONG"))
        #expect(!policy.shouldRebindListener(health: Self.healthy, pingResponse: "PONG"))
    }

    /// The crux of issue #6406: the in-memory health flags read clean, but a
    /// refused probe (no line at all, an empty line, or an error the listener
    /// could not have produced while serving `ping`) means the socket is present
    /// yet refusing connections, so the listener must be rebound rather than
    /// trusted. The password auth-required challenge is deliberately *not* one of
    /// these — see ``healthyPasswordListenerAnsweringAuthChallengeIsServing``.
    @Test func healthyFlagsButRefusedPingForcesRebind() {
        let policy = SocketListenerActivationRecoveryPolicy()
        #expect(!policy.listenerIsServing(health: Self.healthy, pingResponse: nil))
        #expect(policy.shouldRebindListener(health: Self.healthy, pingResponse: nil))
        #expect(policy.shouldRebindListener(health: Self.healthy, pingResponse: ""))
        #expect(policy.shouldRebindListener(health: Self.healthy, pingResponse: "   "))
        #expect(policy.shouldRebindListener(health: Self.healthy, pingResponse: "ERROR"))
    }

    /// In password mode a healthy listener answers an *unauthenticated* `ping`
    /// with the auth-required challenge instead of `PONG`. Receiving it proves
    /// the accept loop is alive and dispatching, so the listener is serving and
    /// must not be rebound — otherwise every activation would tear down a healthy
    /// password-protected listener and drop its connected clients.
    @Test func healthyPasswordListenerAnsweringAuthChallengeIsServing() {
        let policy = SocketListenerActivationRecoveryPolicy()
        // The exact v1 wire string produced by
        // `TerminalController.passwordAuthRequiredResponse` for a plain `ping`.
        let v1Challenge = "ERROR: Authentication required — send auth <password> first"
        #expect(
            v1Challenge.contains(
                SocketListenerActivationRecoveryPolicy.passwordAuthRequiredResponseMarker
            )
        )
        #expect(policy.listenerIsServing(health: Self.healthy, pingResponse: v1Challenge))
        #expect(!policy.shouldRebindListener(health: Self.healthy, pingResponse: v1Challenge))

        // The v2 challenge embeds the same marker inside a JSON error payload.
        let v2Challenge = #"{"id":1,"error":{"code":"auth_required","message":"Authentication required. Send auth <password> first."}}"#
        #expect(policy.listenerIsServing(health: Self.healthy, pingResponse: v2Challenge))
        #expect(!policy.shouldRebindListener(health: Self.healthy, pingResponse: v2Challenge))

        // Surrounding whitespace on the wire must not defeat recognition.
        #expect(policy.listenerIsServing(health: Self.healthy, pingResponse: "  \(v1Challenge)\n"))
    }

    @Test func downListenerForcesRebindRegardlessOfPing() {
        let policy = SocketListenerActivationRecoveryPolicy()
        #expect(!policy.listenerIsServing(health: Self.down, pingResponse: nil))
        #expect(policy.shouldRebindListener(health: Self.down, pingResponse: nil))
        // Even a stray PONG cannot rescue a listener the state machine reports down.
        #expect(policy.shouldRebindListener(health: Self.down, pingResponse: "PONG"))
        // Nor can the auth-required challenge rescue a listener reported down.
        #expect(
            policy.shouldRebindListener(
                health: Self.down,
                pingResponse: "ERROR: Authentication required — send auth <password> first"
            )
        )
    }
}
