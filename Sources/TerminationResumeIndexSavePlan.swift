import Foundation

nonisolated enum TerminationResumeIndexAuthority: Sendable {
    case pending
    case completed(ProcessDetectedResumeIndexes?)
}

nonisolated struct TerminationResumeIndexSavePlan {
    let restorableAgentIndex: RestorableAgentSessionIndex?
    let surfaceResumeBindingIndex: SurfaceResumeBindingIndex?
    let usesCoreSnapshotFallback: Bool

    static func resolve(
        _ authority: TerminationResumeIndexAuthority,
        cachedResumeIndexes: () -> ProcessDetectedResumeIndexes? = { nil }
    ) -> TerminationResumeIndexSavePlan {
        let resumeIndexes: ProcessDetectedResumeIndexes?
        switch authority {
        case .pending:
            resumeIndexes = cachedResumeIndexes()
        case .completed(let completedIndexes):
            resumeIndexes = completedIndexes ?? cachedResumeIndexes()
        }
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
