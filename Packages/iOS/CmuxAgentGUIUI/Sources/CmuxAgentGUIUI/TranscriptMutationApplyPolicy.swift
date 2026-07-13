import Foundation

enum TranscriptMutationApplyMode: Hashable, Sendable {
    case animatedIdleAtBottom
    case nonAnimatedPreservingAnchor
    case nonAnimatedNoOffsetWrite
}

struct TranscriptMutationApplyPolicy: Hashable, Sendable {
    let scrollIsInteracting: Bool
    let distanceFromBottom: Double
    let insertedIndexes: [Int]

    var mode: TranscriptMutationApplyMode {
        if scrollIsInteracting {
            return activeScrollMode
        }
        if distanceFromBottom <= Self.bottomStickinessThreshold {
            return .animatedIdleAtBottom
        }
        return .nonAnimatedPreservingAnchor
    }

    private var activeScrollMode: TranscriptMutationApplyMode {
        guard distanceFromBottom > Self.bottomStickinessThreshold,
              !insertedIndexes.isEmpty
        else {
            return .nonAnimatedNoOffsetWrite
        }
        return .nonAnimatedPreservingAnchor
    }

    static let bottomStickinessThreshold = 40.0
}
