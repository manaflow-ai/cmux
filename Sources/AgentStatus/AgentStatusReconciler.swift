import Foundation

/// Pure priority and expiry rules for agent status evidence.
struct AgentStatusReconciler: Sendable {
    static let runningSignalLifetime: TimeInterval = 90
    static let runningCorroborationLifetime: TimeInterval = 120
    static let activityLifetime: TimeInterval = 45
    static let foregroundObservationLifetime: TimeInterval = 45

    func resolve(
        evidence: AgentStatusEvidence,
        statusKey: String,
        hasLiveRuntime: Bool,
        now: Date
    ) -> AgentStatusResolution? {
        guard hasLiveRuntime else { return nil }
        let promptIdleIsAuthoritative = evidence.shellActivity == .promptIdle && {
            guard let shellObservedAt = evidence.shellActivityObservedAt else { return false }
            return evidence.lifecycleObservedAt.map { shellObservedAt >= $0 } ?? true
        }()
        if promptIdleIsAuthoritative {
            return AgentStatusResolution(lifecycle: .idle, confidence: .confident)
        }
        // Needs Input is an exact-runtime-generation state, not an activity
        // estimate. Keep it until a counter-signal replaces it or that runtime
        // exits; elapsed wall time alone cannot prove a prompt was resolved.
        if evidence.lifecycle == .needsInput {
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
            guard evidence.lifecycleObservedAt != nil else { return unknownResolution() }
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
            guard evidence.lifecycleObservedAt != nil else { return unknownResolution() }
            return AgentStatusResolution(lifecycle: .idle, confidence: .inferred)

        case nil:
            return unknownResolution()
        }
    }

    private func unknownResolution() -> AgentStatusResolution {
        return AgentStatusResolution(lifecycle: .unknown, confidence: .uncertain)
    }

    private func age(of date: Date, now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(date))
    }
}
