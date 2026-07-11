import Foundation

nonisolated enum TerminationResumeIndexAuthority: Sendable {
    case pending
    case completed(ProcessDetectedResumeIndexes?)

    var completedIndexes: ProcessDetectedResumeIndexes? {
        guard case .completed(let indexes) = self else { return nil }
        return indexes
    }
}

nonisolated struct TerminationResumeIndexSavePlan {
    let restorableAgentIndex: RestorableAgentSessionIndex?
    let surfaceResumeBindingIndex: SurfaceResumeBindingIndex?
    let usesCoreSnapshotFallback: Bool

    static func resolve(
        _ authority: TerminationResumeIndexAuthority
    ) -> TerminationResumeIndexSavePlan {
        let resumeIndexes = authority.completedIndexes
        if let resumeIndexes {
            return TerminationResumeIndexSavePlan(
                restorableAgentIndex: resumeIndexes.restorableAgentIndex,
                surfaceResumeBindingIndex: resumeIndexes.surfaceResumeBindingIndex,
                usesCoreSnapshotFallback: false
            )
        }
        return TerminationResumeIndexSavePlan(
            // An explicit empty process augmentation keeps the core snapshot
            // path from scheduling a second cold shared-index refresh.
            restorableAgentIndex: .empty,
            surfaceResumeBindingIndex: nil,
            usesCoreSnapshotFallback: true
        )
    }
}
