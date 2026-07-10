import Foundation

/// Owns the one fresh process-index result used throughout a confirmed termination.
@MainActor
final class TerminationResumeIndexCoordinator {
    private typealias PendingLoad = (
        id: UUID,
        task: Task<ProcessDetectedResumeIndexes?, Never>
    )

    private var completed: ProcessDetectedResumeIndexes?
    private var pendingLoad: PendingLoad?

    func load() async -> ProcessDetectedResumeIndexes? {
        await load(coordinatedBy: .shared)
    }

    func load(
        coordinatedBy sharedIndex: SharedLiveAgentIndex
    ) async -> ProcessDetectedResumeIndexes? {
        if let completed {
            return completed
        }

        let pending: PendingLoad
        if let pendingLoad {
            pending = pendingLoad
        } else {
            let id = UUID()
            let task = Task { @MainActor in
                await ProcessDetectedResumeIndexes.load(
                    coordinatedBy: sharedIndex,
                    maximumAge: 5
                )
            }
            pending = (id: id, task: task)
            pendingLoad = pending
        }

        let result = await pending.task.value
        if pendingLoad?.id == pending.id {
            completed = result
            pendingLoad = nil
        }
        return completed ?? result
    }

    func current() -> ProcessDetectedResumeIndexes? {
        current(coordinatedBy: .shared)
    }

    func current(
        coordinatedBy sharedIndex: SharedLiveAgentIndex
    ) -> ProcessDetectedResumeIndexes? {
        completed ?? sharedIndex.currentResumeIndexesSchedulingRefresh()
    }

}

extension AppDelegate {
    @discardableResult
    func saveSessionSnapshotAfterCoordinatingProcessDetectedIndexes(
        includeScrollback: Bool,
        removeWhenEmpty: Bool
    ) async -> Bool {
        guard let resumeIndexes = await terminationResumeIndexCoordinator.load() else {
            return saveSessionSnapshotIncludingProcessDetectedIndexes(
                includeScrollback: includeScrollback,
                removeWhenEmpty: removeWhenEmpty
            )
        }
        return saveSessionSnapshot(
            includeScrollback: includeScrollback,
            removeWhenEmpty: removeWhenEmpty,
            restorableAgentIndex: resumeIndexes.restorableAgentIndex,
            surfaceResumeBindingIndex: resumeIndexes.surfaceResumeBindingIndex
        )
    }

    func beginConfirmedAppTermination(reason: String) {
        guard terminationPreparationTask == nil else { return }
        isTerminatingApp = true
        _ = nextProcessDetectedSessionSaveGeneration()
        terminationPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let resumeIndexes = await self.terminationResumeIndexCoordinator.load()
            guard !Task.isCancelled else { return }
            if let resumeIndexes {
                _ = self.saveSessionSnapshot(
                    includeScrollback: true,
                    removeWhenEmpty: false,
                    restorableAgentIndex: resumeIndexes.restorableAgentIndex,
                    surfaceResumeBindingIndex: resumeIndexes.surfaceResumeBindingIndex
                )
            } else {
                _ = self.saveSessionSnapshotIncludingProcessDetectedIndexes(
                    includeScrollback: true,
                    removeWhenEmpty: false
                )
            }
            ClosedItemHistoryStore.shared.flushPendingSaves()
            // The snapshot is durable before AppKit's potentially blocking termination observers run.
            self.terminationWatchdog.arm()
            self.closeAllWebInspectorsBeforeAppTeardown()
            self.terminationPreparationTask = nil
            StartupBreadcrumbLog.append(
                "appDelegate.shouldTerminate.reply",
                fields: ["shouldQuit": "1", "reason": reason]
            )
            if !self.deferTerminateForMarkedRemoteTmuxKills(reason: reason) {
                self.replyToTerminateOnce(true)
            }
        }
    }
}
