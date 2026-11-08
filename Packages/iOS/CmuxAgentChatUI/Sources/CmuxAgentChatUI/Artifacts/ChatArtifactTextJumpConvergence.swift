/// Bounded policy for retargeting a document-boundary scroll after layout changes.
struct ChatArtifactTextJumpConvergence: Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        case finish
        case retarget(offset: Double)
        case force(offset: Double)
    }

    private let tolerance: Double
    private var previousTargetOffset: Double
    private var remainingRetargetCount: Int
    // A synchronous settle callback must not claim the forced fallback twice.
    private var exhaustedRetargetBudget = false

    init(
        initialTargetOffset: Double,
        maximumRetargetCount: Int = 24,
        tolerance: Double = 0.5
    ) {
        previousTargetOffset = initialTargetOffset
        remainingRetargetCount = max(0, maximumRetargetCount)
        self.tolerance = max(0, tolerance)
    }

    mutating func decision(observedOffset: Double, targetOffset: Double) -> Decision {
        guard !exhaustedRetargetBudget else { return .finish }

        let reachedTarget = abs(observedOffset - targetOffset) <= tolerance
        let targetIsStable = abs(previousTargetOffset - targetOffset) <= tolerance
        if reachedTarget, targetIsStable {
            return .finish
        }

        previousTargetOffset = targetOffset
        guard remainingRetargetCount > 0 else {
            exhaustedRetargetBudget = true
            return .force(offset: targetOffset)
        }
        remainingRetargetCount -= 1
        return .retarget(offset: targetOffset)
    }
}
