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

    // MARK: - Telemetry-safe ping classification

    /// The breadcrumb kind is a bounded classification (never the raw response)
    /// and stays coupled to the serving decision: exactly the kinds that prove a
    /// live listener (`pong`, `authChallenge`) are the ones treated as serving.
    @Test func pingResponseKindClassifiesEveryResponse() {
        let policy = SocketListenerActivationRecoveryPolicy()
        #expect(policy.pingResponseKind(nil) == .missing)
        #expect(policy.pingResponseKind("") == .empty)
        #expect(policy.pingResponseKind("   \n") == .empty)
        #expect(policy.pingResponseKind("PONG") == .pong)
        #expect(policy.pingResponseKind("  PONG\n") == .pong)
        #expect(
            policy.pingResponseKind("ERROR: Authentication required — send auth <password> first")
                == .authChallenge
        )
        #expect(policy.pingResponseKind("ERROR: unknown command") == .unexpected)

        // Coupling guarantee: a kind proves the listener is serving iff it is one
        // of the known live-listener replies.
        for kind in SocketListenerActivationPingResponseKind.allCases {
            let proves = (kind == .pong || kind == .authChallenge)
            switch kind {
            case .pong:
                #expect(policy.pingResponseProvesListenerServing("PONG") == proves)
            case .authChallenge:
                #expect(
                    policy.pingResponseProvesListenerServing(
                        "ERROR: Authentication required — send auth <password> first"
                    ) == proves
                )
            case .empty:
                #expect(policy.pingResponseProvesListenerServing("") == proves)
            case .unexpected:
                #expect(policy.pingResponseProvesListenerServing("nope") == proves)
            case .missing:
                break  // `missing` is the nil case, exercised via listenerIsServing.
            }
        }
    }

    // MARK: - Activation/wake race (generation staleness)

    /// A rebind decision derived from a probe holds only while the accept-loop
    /// generation is unchanged. If any recovery path replaces the listener
    /// during the probe the generation moves — a restart stamps a fresh, higher
    /// id; a stop resets it to `0` — and the decision is stale, so the freshly
    /// recovered listener is not torn down.
    @Test func rebindDecisionIsStaleWhenListenerRebornDuringProbe() {
        let policy = SocketListenerActivationRecoveryPolicy()
        // Same generation: the probed listener is still the live one.
        #expect(policy.rebindDecisionIsCurrent(capturedGeneration: 7, currentGeneration: 7))
        // A concurrent restart stamps a fresh, higher accept-loop generation.
        #expect(!policy.rebindDecisionIsCurrent(capturedGeneration: 7, currentGeneration: 8))
        // A concurrent stop resets the active accept-loop generation to 0.
        #expect(!policy.rebindDecisionIsCurrent(capturedGeneration: 7, currentGeneration: 0))
    }

    /// The rebind may proceed only when the decision is still current *and* the
    /// server is not already recovering the accept loop on its own. During the
    /// listener's own accept-source backoff (a parked rearm or a suspended accept
    /// source) the generation is unchanged — so the freshness check alone passes
    /// — yet the listener reads like the refused socket the heal targets. Acting
    /// then would restart over the scheduled recovery and reset the accept-failure
    /// streak, defeating the backoff, so a pending server recovery must block the
    /// rebind regardless of generation (#6406 review, backoff preservation).
    @Test func rebindProceedsOnlyWhenCurrentAndNoServerRecoveryPending() {
        let policy = SocketListenerActivationRecoveryPolicy()
        // Current generation, no server recovery, not terminating: the one case
        // that proceeds.
        #expect(
            policy.rebindShouldProceed(
                capturedGeneration: 7,
                currentGeneration: 7,
                serverRecoveryPending: false,
                isTerminating: false
            )
        )
        // Current generation but the server is mid-backoff: defer to it.
        #expect(
            !policy.rebindShouldProceed(
                capturedGeneration: 7,
                currentGeneration: 7,
                serverRecoveryPending: true,
                isTerminating: false
            )
        )
        // Stale generation alone blocks the rebind even with no recovery pending.
        #expect(
            !policy.rebindShouldProceed(
                capturedGeneration: 7,
                currentGeneration: 8,
                serverRecoveryPending: false,
                isTerminating: false
            )
        )
        // Both stale and recovering: still blocked.
        #expect(
            !policy.rebindShouldProceed(
                capturedGeneration: 7,
                currentGeneration: 8,
                serverRecoveryPending: true,
                isTerminating: false
            )
        )
    }

    /// App teardown must block the rebind even when every other signal says
    /// proceed. The `ping` probe runs off the main actor, so app termination or an
    /// updater relaunch can run `TerminalController.stop()` mid-probe and reset
    /// the accept-loop generation to 0 on purpose. A probe that captured 0 would
    /// otherwise see `0 == 0`, pass the currency check with nothing pending, and
    /// resurrect the socket the teardown path just stopped. `isTerminating` gates
    /// that unconditionally (#6406 review, teardown race).
    @Test func terminatingBlocksRebindEvenWhenOtherwiseCurrent() {
        let policy = SocketListenerActivationRecoveryPolicy()
        // The exact teardown race: generation reset to 0, probe also captured 0,
        // nothing pending — the currency check passes, so only the terminating
        // gate stops the resurrection.
        #expect(
            !policy.rebindShouldProceed(
                capturedGeneration: 0,
                currentGeneration: 0,
                serverRecoveryPending: false,
                isTerminating: true
            )
        )
        // Terminating overrides an otherwise-proceeding decision at any generation.
        #expect(
            !policy.rebindShouldProceed(
                capturedGeneration: 7,
                currentGeneration: 7,
                serverRecoveryPending: false,
                isTerminating: true
            )
        )
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
