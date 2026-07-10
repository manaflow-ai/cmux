import Foundation

nonisolated struct TerminationResumeIndexSavePlan {
    let restorableAgentIndex: RestorableAgentSessionIndex?
    let surfaceResumeBindingIndex: SurfaceResumeBindingIndex?
    let usesCoreSnapshotFallback: Bool

    static func resolve(
        _ resumeIndexes: ProcessDetectedResumeIndexes?,
        cachedResumeIndexes: () -> ProcessDetectedResumeIndexes? = { nil }
    ) -> TerminationResumeIndexSavePlan {
        if let resumeIndexes = resumeIndexes ?? cachedResumeIndexes() {
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

nonisolated struct UpdateRelaunchResumeIndexResolver {
    private let cachedIndexes: () -> ProcessDetectedResumeIndexes?
    private let loadSynchronously: () -> ProcessDetectedResumeIndexes

    init(
        cachedIndexes: @escaping () -> ProcessDetectedResumeIndexes?,
        loadSynchronously: @escaping () -> ProcessDetectedResumeIndexes
    ) {
        self.cachedIndexes = cachedIndexes
        self.loadSynchronously = loadSynchronously
    }

    func resolve(
        completedTerminationIndexes: ProcessDetectedResumeIndexes?
    ) -> ProcessDetectedResumeIndexes? {
        completedTerminationIndexes
            ?? cachedIndexes()
            ?? loadSynchronously()
    }
}
