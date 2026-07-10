import Foundation

struct TerminationResumeIndexSavePlan {
    let restorableAgentIndex: RestorableAgentSessionIndex?
    let surfaceResumeBindingIndex: SurfaceResumeBindingIndex?
    let usesCoreSnapshotFallback: Bool

    static func resolve(
        _ resumeIndexes: ProcessDetectedResumeIndexes?
    ) -> TerminationResumeIndexSavePlan {
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
