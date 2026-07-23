import Foundation

/// Pure priority and expiry rules for agent status evidence.
struct AgentStatusReconciler: Sendable {
    static let runningSignalLifetime: TimeInterval = 90
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

        let latestActivity = [evidence.outputObservedAt, evidence.titleObservedAt]
            .compactMap { $0 }
            .max()
        let foregroundIsFresh = evidence.foregroundObservedAt.map {
            age(of: $0, now: now) <= Self.foregroundObservationLifetime
        } ?? false
        let activityIsFresh = latestActivity.map {
            age(of: $0, now: now) <= Self.activityLifetime
        } ?? false
        let hasAttributedActivity = foregroundIsFresh
            && activityIsFresh
            && evidence.foregroundAgentStatusKey == statusKey

        switch evidence.lifecycle {
        case .needsInput?:
            return inferredRunningOrUnknown(hasAttributedActivity: hasAttributedActivity)

        case .idle?:
            guard let observedAt = evidence.lifecycleObservedAt else {
                return inferredRunningOrUnknown(hasAttributedActivity: hasAttributedActivity)
            }
            if hasAttributedActivity,
               let latestActivity,
               latestActivity > observedAt {
                return AgentStatusResolution(lifecycle: .running, confidence: .inferred)
            }
            return AgentStatusResolution(lifecycle: .idle, confidence: .confident)

        case .running?:
            if let observedAt = evidence.lifecycleObservedAt,
               age(of: observedAt, now: now) <= Self.runningSignalLifetime {
                return AgentStatusResolution(lifecycle: .running, confidence: .confident)
            }
            return inferredRunningOrUnknown(hasAttributedActivity: hasAttributedActivity)

        case .unknown?, nil:
            return inferredRunningOrUnknown(hasAttributedActivity: hasAttributedActivity)
        }
    }

    private func inferredRunningOrUnknown(
        hasAttributedActivity: Bool
    ) -> AgentStatusResolution {
        if hasAttributedActivity {
            return AgentStatusResolution(lifecycle: .running, confidence: .inferred)
        }
        return AgentStatusResolution(lifecycle: .unknown, confidence: .uncertain)
    }

    private func age(of date: Date, now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(date))
    }
}
