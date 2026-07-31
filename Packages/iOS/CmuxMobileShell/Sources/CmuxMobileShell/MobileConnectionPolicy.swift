internal import CmuxMobileRPC

/// Connection evidence taxonomy (docs/transport-plane.md, D2).
///
/// Every signal that historically triggered recovery is one of these cases.
/// Producers report what they observed; only ``MobileConnectionPolicy``
/// decides what happens, and only the recovery owner executes it.
enum MobileConnectionEvidence: Equatable, Sendable, CaseIterable {
    // Health-fatal: the transport itself reported the session dead.
    case transportClosed
    case allPathsUnavailable
    // Authorization: the peer or broker rejected our authority.
    case authorizationLost
    // Health-suspect: app-level silence or stream failure on a session the
    // transport has not declared dead.
    case livenessSilence
    case eventStreamEnded
    case subscriptionStartFailed
    case rpcWriteTimedOut
    // Opportunity: a moment when reconciling desired state is cheap or
    // user-requested. Never death evidence by itself.
    case foreground
    case networkPathChanged
    case presenceRoutePush
    case manualRetry
    case backoffExpired
}

/// What the policy tells the recovery owner to do (docs/transport-plane.md,
/// D3, D11). Mechanics (generation guards, task ownership, deadlines) stay
/// in the owner; this type is pure decision.
enum MobileConnectionPolicyAction: Equatable, Sendable {
    /// No action; the connection is fine or the evidence is moot.
    case none
    /// Repair subscriptions/streams on the live session without touching
    /// the connection (resync: re-subscribe events, replay from cursors).
    case resubscribe
    /// Claim the owner for a probe on the live session; a healthy probe
    /// resyncs, a failed probe escalates to one stored-Mac redial.
    case probeThenEscalate
    /// Claim the owner for a teardown-and-redial.
    case redial
    /// Tear down and stay down until authorization is repaired (sign-in,
    /// re-pair). Automatic dials must not restart on health evidence.
    case stopUntilAuthorizationRepaired
}

/// Inputs the policy needs beyond the evidence itself.
struct MobileConnectionPolicyContext: Equatable, Sendable {
    /// Whether the shell currently holds a live connection to the Mac.
    var isConnected: Bool
    /// Credential-free transport-path health for the live session.
    /// `.unknown` preserves pre-gate behavior (legacy transports, tests).
    var pathHealth: MobileTransportPathHealth
    /// Whether automatic (non-manual) dials are currently blocked by the
    /// account backoff ladder or a broker cooldown.
    var automaticReconnectBlocked: Bool
    /// Consecutive lightweight repairs (``MobileConnectionPolicyAction/resubscribe``)
    /// already attempted on this connection generation without the data
    /// plane recovering. Bounds the resubscribe ladder so repeated suspect
    /// evidence escalates instead of looping (D2's "redial ONLY if ...
    /// probe proves the session dead" ladder).
    var consecutiveRepairAttempts: Int = 0

    init(
        isConnected: Bool,
        pathHealth: MobileTransportPathHealth,
        automaticReconnectBlocked: Bool,
        consecutiveRepairAttempts: Int = 0
    ) {
        self.isConnected = isConnected
        self.pathHealth = pathHealth
        self.automaticReconnectBlocked = automaticReconnectBlocked
        self.consecutiveRepairAttempts = consecutiveRepairAttempts
    }
}

/// Pure escalation policy for one Mac connection (docs/transport-plane.md,
/// invariant I1): app-level evidence never tears down a session the
/// transport reports healthy; transport-health failure, authorization
/// change, supersede, and user action remain the only close reasons.
enum MobileConnectionPolicy {
    static func action(
        for evidence: MobileConnectionEvidence,
        in context: MobileConnectionPolicyContext
    ) -> MobileConnectionPolicyAction {
        switch evidence {
        case .authorizationLost:
            return .stopUntilAuthorizationRepaired

        case .transportClosed, .allPathsUnavailable:
            // The transport declared the session dead. Disconnected shells
            // have nothing to redial here; the next opportunity or the
            // backoff timer owns the retry.
            return context.isConnected ? .redial : .none

        case .livenessSilence, .eventStreamEnded:
            guard context.isConnected else { return .none }
            switch context.pathHealth {
            case .healthy:
                // The path is usable, so the silence is a stream/subscription
                // problem: repair in place. After a bounded number of
                // fruitless repairs, escalate through a probe (which proves
                // the session dead or alive) instead of looping.
                return context.consecutiveRepairAttempts < 1
                    ? .resubscribe
                    : .probeThenEscalate
            case .noPath:
                return .redial
            case .unknown:
                // Pre-gate behavior: liveness silence probes first;
                // a definitively ended event stream redials.
                return evidence == .livenessSilence ? .probeThenEscalate : .redial
            }

        case .subscriptionStartFailed, .rpcWriteTimedOut:
            guard context.isConnected else { return .none }
            switch context.pathHealth {
            case .healthy:
                // The path works but a control-plane operation failed.
                // A probe round-trip decides between resync and redial;
                // blind resubscribe would retry the exact failed operation.
                return .probeThenEscalate
            case .noPath:
                return .redial
            case .unknown:
                return .redial
            }

        case .foreground, .networkPathChanged:
            if context.isConnected {
                switch context.pathHealth {
                case .noPath:
                    return .redial
                case .healthy, .unknown:
                    // Cheap revalidation of a connection we believe is live;
                    // fgrc rules make probes invisible and suspension-safe.
                    return .probeThenEscalate
                }
            }
            return context.automaticReconnectBlocked ? .none : .redial

        case .presenceRoutePush:
            if context.isConnected {
                switch context.pathHealth {
                case .healthy: return .none
                case .noPath: return .redial
                case .unknown: return .probeThenEscalate
                }
            }
            return context.automaticReconnectBlocked ? .none : .redial

        case .manualRetry:
            // The user asked: always act. Callers clear transient backoff
            // before consulting the policy; broker cooldowns still apply at
            // the dial layer.
            return context.isConnected ? .probeThenEscalate : .redial

        case .backoffExpired:
            guard !context.isConnected else { return .none }
            return context.automaticReconnectBlocked ? .none : .redial
        }
    }
}
