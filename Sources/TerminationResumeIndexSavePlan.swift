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
            // A pending capture cannot prove that cached process bindings still
            // describe the current termination attempt, so preserve core state only.
            resumeIndexes = nil
        case .completed(let completedIndexes):
            resumeIndexes = completedIndexes
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

    init(
        cachedIndexes: @escaping () -> ProcessDetectedResumeIndexes?
    ) {
        self.cachedIndexes = cachedIndexes
    }

    func resolve(
        coordinatedBy authority: TerminationResumeIndexAuthority
    ) -> ProcessDetectedResumeIndexes? {
        switch authority {
        case .pending:
            // Relaunch preparation must not reuse bindings captured before this attempt.
            return nil
        case .completed(let completedIndexes):
            return completedIndexes
        }
    }
}
