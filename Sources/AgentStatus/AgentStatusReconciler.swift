import Foundation

/// Pure priority and expiry rules for agent status evidence.
struct AgentStatusReconciler: Sendable {
    static let runningSignalLifetime: TimeInterval = 90
    static let activityLifetime: TimeInterval = 45
    static let foregroundObservationLifetime: TimeInterval = 45
    // Session/Stop hooks are followed by TUI redraws; only later activity may contradict them.
    static let lifecycleTransitionActivityGrace: TimeInterval = 15

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

        let corroboratedActivityAt = [evidence.outputObservedAt, evidence.titleObservedAt]
            .compactMap { $0 }
            .min()
        let foregroundIsFresh = evidence.foregroundObservedAt.map {
            age(of: $0, now: now) <= Self.foregroundObservationLifetime
        } ?? false
        let outputIsFresh = evidence.outputObservedAt.map {
            age(of: $0, now: now) <= Self.activityLifetime
        } ?? false
        let titleIsFresh = evidence.titleObservedAt.map {
            age(of: $0, now: now) <= Self.activityLifetime
        } ?? false
        // A foreground TUI can redraw while waiting at an empty prompt. PTY
        // output is only active-turn evidence when a title transition
        // independently corroborates it.
        let hasCorroboratedActivity = foregroundIsFresh
            && outputIsFresh
            && titleIsFresh
            && evidence.foregroundAgentStatusKey == statusKey

        switch evidence.lifecycle {
        case .needsInput?:
            return inferredRunningOrUnknown(hasCorroboratedActivity: hasCorroboratedActivity)

        case .idle?:
            guard let observedAt = evidence.lifecycleObservedAt else {
                return inferredRunningOrUnknown(hasCorroboratedActivity: hasCorroboratedActivity)
            }
            if hasCorroboratedActivity,
               let corroboratedActivityAt,
               activityCanOverrideTransition(activityAt: corroboratedActivityAt, transitionAt: observedAt) {
                return AgentStatusResolution(lifecycle: .running, confidence: .inferred)
            }
            return AgentStatusResolution(lifecycle: .idle, confidence: .confident)

        case .running?:
            if let observedAt = evidence.lifecycleObservedAt,
               age(of: observedAt, now: now) <= Self.runningSignalLifetime {
                return AgentStatusResolution(lifecycle: .running, confidence: .confident)
            }
            return inferredRunningOrUnknown(hasCorroboratedActivity: hasCorroboratedActivity)

        case .unknown?:
            guard let observedAt = evidence.lifecycleObservedAt else {
                return inferredRunningOrUnknown(hasCorroboratedActivity: hasCorroboratedActivity)
            }
            if hasCorroboratedActivity,
               let corroboratedActivityAt,
               activityCanOverrideTransition(activityAt: corroboratedActivityAt, transitionAt: observedAt) {
                return AgentStatusResolution(lifecycle: .running, confidence: .inferred)
            }
            return AgentStatusResolution(lifecycle: .idle, confidence: .inferred)

        case nil:
            return inferredRunningOrUnknown(hasCorroboratedActivity: hasCorroboratedActivity)
        }
    }

    private func inferredRunningOrUnknown(
        hasCorroboratedActivity: Bool
    ) -> AgentStatusResolution {
        if hasCorroboratedActivity {
            return AgentStatusResolution(lifecycle: .running, confidence: .inferred)
        }
        return AgentStatusResolution(lifecycle: .unknown, confidence: .uncertain)
    }

    private func activityCanOverrideTransition(activityAt: Date, transitionAt: Date) -> Bool {
        activityAt.timeIntervalSince(transitionAt) > Self.lifecycleTransitionActivityGrace
    }

    private func age(of date: Date, now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(date))
    }
}
