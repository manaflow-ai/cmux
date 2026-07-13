import Foundation

/// Owns the one fresh process-index result used throughout a confirmed termination.
@MainActor
final class TerminationResumeIndexCoordinator {
    private typealias PendingLoad = (
        id: UUID,
        task: Task<ProcessDetectedResumeIndexes?, Never>
    )

    private var completed: ProcessDetectedResumeIndexes?
    private var didComplete = false
    private var pendingLoad: PendingLoad?

    func loadForNewTerminationAttempt() async -> ProcessDetectedResumeIndexes? {
        await loadForNewTerminationAttempt(coordinatedBy: .shared)
    }

    func loadForNewTerminationAttempt(
        coordinatedBy sharedIndex: SharedLiveAgentIndex
    ) async -> ProcessDetectedResumeIndexes? {
        invalidate()
        return await load(coordinatedBy: sharedIndex)
    }

    func invalidate() {
        pendingLoad?.task.cancel()
        pendingLoad = nil
        completed = nil
        didComplete = false
    }

    func load() async -> ProcessDetectedResumeIndexes? {
        await load(coordinatedBy: .shared)
    }

    func load(
        coordinatedBy sharedIndex: SharedLiveAgentIndex
    ) async -> ProcessDetectedResumeIndexes? {
        if didComplete {
            return completed
        }

        let pending: PendingLoad
        if let pendingLoad {
            pending = pendingLoad
        } else {
            let id = UUID()
            let task = Task { @MainActor in
                await ProcessDetectedResumeIndexes.loadCapturedAfterRequest(
                    coordinatedBy: sharedIndex
                )
            }
            pending = (id: id, task: task)
            pendingLoad = pending
        }

        let result = await pending.task.value
        guard pendingLoad?.id == pending.id else {
            return current()
        }
        completed = result
        didComplete = true
        pendingLoad = nil
        return result
    }

    func current() -> ProcessDetectedResumeIndexes? {
        guard didComplete else { return nil }
        return completed
    }

    func resolution() -> TerminationResumeIndexAuthority {
        guard didComplete else { return .pending }
        return .completed(completed)
    }

}

extension AppDelegate {
    @discardableResult
    func saveSessionSnapshotAfterCoordinatingProcessDetectedIndexes(
        includeScrollback: Bool,
        removeWhenEmpty: Bool
    ) async -> Bool {
        let coreSnapshotSaved = saveSessionSnapshotIncludingProcessDetectedIndexes(
            includeScrollback: includeScrollback,
            removeWhenEmpty: removeWhenEmpty
        )
        guard let resumeIndexes = await terminationResumeIndexCoordinator.load() else {
            return coreSnapshotSaved
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
        confirmedTerminationSessionCapture.prepare { [weak self] in
            guard let self else { return }
            _ = self.saveSessionSnapshotIncludingProcessDetectedIndexes(
                includeScrollback: true,
                removeWhenEmpty: false
            )
            ClosedItemHistoryStore.shared.flushPendingSaves()
        }
        terminationPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.confirmedTerminationSessionCapture.captureBeforeTeardown(
                using: {
                    await self.terminationResumeIndexCoordinator.loadForNewTerminationAttempt()
                },
                beginTeardown: {
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
            )
        }
    }
}
