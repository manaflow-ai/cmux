import Foundation

struct TerminationResumeIndexSavePlan {
    let resumeIndexes: ProcessDetectedResumeIndexes
    let usesCoreSnapshotFallback: Bool

    static func resolve(
        _ resumeIndexes: ProcessDetectedResumeIndexes?
    ) -> TerminationResumeIndexSavePlan {
        if let resumeIndexes {
            return TerminationResumeIndexSavePlan(
                resumeIndexes: resumeIndexes,
                usesCoreSnapshotFallback: false
            )
        }
        return TerminationResumeIndexSavePlan(
            resumeIndexes: ProcessDetectedResumeIndexes(
                restorableAgentIndex: .empty,
                surfaceResumeBindingIndex: .empty
            ),
            usesCoreSnapshotFallback: true
        )
    }
}
