import Foundation

/// Pure priority and expiry rules for agent status evidence.
struct AgentStatusReconciler: Sendable {
    static let runningSignalLifetime: TimeInterval = 90
    static let runningCorroborationLifetime: TimeInterval = 120
    static let activityLifetime: TimeInterval = 45
    static let foregroundObservationLifetime: TimeInterval = 45
    static let unverifiableRuntimeSignalLifetime: TimeInterval = 300

    func resolve(
        evidence: AgentStatusEvidence,
        statusKey: String,
        runtimeLiveness: AgentStatusRuntimeLiveness,
        now: Date
    ) -> AgentStatusResolution? {
        guard runtimeLiveness != .absent else { return nil }
        let promptIdleIsAuthoritative = evidence.shellActivity == .promptIdle && {
            guard let shellObservedAt = evidence.shellActivityObservedAt else { return false }
            return evidence.lifecycleObservedAt.map { shellObservedAt >= $0 } ?? true
        }()
        if promptIdleIsAuthoritative {
            guard signalRemainsTrustworthy(
                for: runtimeLiveness,
                observedAt: evidence.shellActivityObservedAt,
                now: now
            ) else { return unknownResolution() }
            return AgentStatusResolution(lifecycle: .idle, confidence: .confident)
        }
        // Needs Input is an exact-runtime-generation state, not an activity
        // estimate. Keep it until a counter-signal replaces it or that runtime
        // exits. A remote surface proves only addressability, so its last exact
        // hook signal eventually becomes unknown instead of claiming liveness.
        if evidence.lifecycle == .needsInput {
            guard signalRemainsTrustworthy(
                for: runtimeLiveness,
                observedAt: evidence.lifecycleObservedAt,
                now: now
            ) else { return unknownResolution() }
            return AgentStatusResolution(lifecycle: .needsInput, confidence: .confident)
        }

        let foregroundIsFresh = evidence.foregroundObservedAt.map {
            age(of: $0, now: now) <= Self.foregroundObservationLifetime
        } ?? false
        let outputIsFresh = evidence.outputObservedAt.map {
            age(of: $0, now: now) <= Self.activityLifetime
        } ?? false
        let titleIsFresh = evidence.titleObservedAt.map {
            age(of: $0, now: now) <= Self.activityLifetime
        } ?? false
        // Output and title changes can corroborate a known turn, but cannot
        // establish one: an idle foreground TUI can produce all three signals.
        let hasCorroboratedActivity = foregroundIsFresh
            && outputIsFresh
            && titleIsFresh
            && evidence.foregroundAgentStatusKey == statusKey

        switch evidence.lifecycle {
        case .needsInput?:
            return unknownResolution()

        case .idle?:
            guard signalRemainsTrustworthy(
                for: runtimeLiveness,
                observedAt: evidence.lifecycleObservedAt,
                now: now
            ) else { return unknownResolution() }
            return AgentStatusResolution(lifecycle: .idle, confidence: .confident)

        case .running?:
            guard let observedAt = evidence.lifecycleObservedAt else { return unknownResolution() }
            let lifecycleAge = age(of: observedAt, now: now)
            if lifecycleAge <= Self.runningSignalLifetime {
                return AgentStatusResolution(lifecycle: .running, confidence: .confident)
            }
            if lifecycleAge <= Self.runningCorroborationLifetime, hasCorroboratedActivity {
                return AgentStatusResolution(lifecycle: .running, confidence: .inferred)
            }
            return unknownResolution()

        case .unknown?:
            return unknownResolution()

        case nil:
            return unknownResolution()
        }
    }

    private func unknownResolution() -> AgentStatusResolution {
        return AgentStatusResolution(lifecycle: .unknown, confidence: .uncertain)
    }

    private func signalRemainsTrustworthy(
        for runtimeLiveness: AgentStatusRuntimeLiveness,
        observedAt: Date?,
        now: Date
    ) -> Bool {
        switch runtimeLiveness {
        case .confirmed:
            return true
        case .unverifiable:
            guard let observedAt else { return false }
            return age(of: observedAt, now: now) <= Self.unverifiableRuntimeSignalLifetime
        case .absent:
            return false
        }
    }

    private func age(of date: Date, now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(date))
    }
}
