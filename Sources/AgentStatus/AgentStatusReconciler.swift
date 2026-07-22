import Foundation

/// Pure priority and expiry rules for agent status evidence.
struct AgentStatusReconciler: Sendable {
    static let runningSignalLifetime: TimeInterval = 90
    static let needsInputSignalLifetime: TimeInterval = 300
    static let activityLifetime: TimeInterval = 20
    static let foregroundObservationLifetime: TimeInterval = 45
    static let needsInputActivityGrace: TimeInterval = 5

    func resolve(
        evidence: AgentStatusEvidence,
        statusKey: String,
        hasLiveRuntime: Bool,
        now: Date
    ) -> AgentStatusResolution? {
        guard hasLiveRuntime else { return nil }
        if evidence.shellActivity == .promptIdle {
            return AgentStatusResolution(lifecycle: .idle, confidence: .confident)
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
            guard let observedAt = evidence.lifecycleObservedAt,
                  age(of: observedAt, now: now) <= Self.needsInputSignalLifetime else {
                return inferredRunningOrUnknown(hasAttributedActivity: hasAttributedActivity)
            }
            if hasAttributedActivity,
               let latestActivity,
               latestActivity.timeIntervalSince(observedAt) > Self.needsInputActivityGrace {
                return AgentStatusResolution(lifecycle: .running, confidence: .inferred)
            }
            return AgentStatusResolution(lifecycle: .needsInput, confidence: .confident)

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
