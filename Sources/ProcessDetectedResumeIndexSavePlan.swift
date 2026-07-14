import Foundation

nonisolated enum TerminationResumeIndexAuthority: Sendable {
    case pending
    case completed(ProcessDetectedResumeIndexes?)
}

nonisolated struct ProcessDetectedResumeIndexSavePlan {
    let restorableAgentIndex: RestorableAgentSessionIndex
    let surfaceResumeBindingIndex: SurfaceResumeBindingIndex
    let usesCoreSnapshotFallback: Bool

    static func resolve(
        _ resumeIndexes: ProcessDetectedResumeIndexes?
    ) -> ProcessDetectedResumeIndexSavePlan {
        if let resumeIndexes {
            return ProcessDetectedResumeIndexSavePlan(
                restorableAgentIndex: resumeIndexes.restorableAgentIndex,
                surfaceResumeBindingIndex: resumeIndexes.surfaceResumeBindingIndex,
                usesCoreSnapshotFallback: false
            )
        }
        return ProcessDetectedResumeIndexSavePlan(
            // An explicit empty process augmentation keeps the core snapshot
            // path from scheduling a second cold shared-index refresh.
            restorableAgentIndex: .empty,
            // Reconcile against an authoritative empty scan so stale
            // process-detected bindings are removed while durable bindings remain.
            surfaceResumeBindingIndex: .empty,
            usesCoreSnapshotFallback: true
        )
    }

    static func resolve(
        _ authority: TerminationResumeIndexAuthority,
        cachedResumeIndexes: () -> ProcessDetectedResumeIndexes? = { nil }
    ) -> ProcessDetectedResumeIndexSavePlan {
        let resumeIndexes: ProcessDetectedResumeIndexes?
        switch authority {
        case .pending:
            // A pending capture cannot prove that cached process bindings still
            // describe the current termination attempt, so preserve core state only.
            resumeIndexes = nil
        case .completed(let completedIndexes):
            resumeIndexes = completedIndexes
        }
        return resolve(resumeIndexes)
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
