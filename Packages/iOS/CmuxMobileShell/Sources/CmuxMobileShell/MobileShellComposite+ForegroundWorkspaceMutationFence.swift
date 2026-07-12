struct ForegroundWorkspaceMutationRefreshResult: Sendable {
    let epoch: UInt64
    let succeeded: Bool
}

extension MobileShellComposite {
    /// Starts a foreground read after a mutation acknowledgement. An older pull
    /// may contain the pre-mutation hierarchy, so it must settle before this read.
    func refreshForegroundWorkspaceListAfterMutation() async -> Bool {
        let epoch = advanceForegroundWorkspaceListMutationEpoch()
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return ForegroundWorkspaceMutationRefreshResult(epoch: epoch, succeeded: false)
            }
            if let inFlight = self.pullToRefreshTask {
                _ = await inFlight.value
            }
            guard self.connectionState == .connected, self.remoteClient != nil else {
                return ForegroundWorkspaceMutationRefreshResult(epoch: epoch, succeeded: false)
            }
            let succeeded = await self.reloadWorkspaceListFromMac()
            return ForegroundWorkspaceMutationRefreshResult(epoch: epoch, succeeded: succeeded)
        }
        foregroundWorkspaceMutationRefreshTask = task
        let result = await task.value
        if result.succeeded || foregroundWorkspaceListAppliedMutationEpoch >= epoch {
            return true
        }
        guard foregroundWorkspaceListMutationEpoch > epoch,
              let latestTask = foregroundWorkspaceMutationRefreshTask else { return false }
        let latestResult = await latestTask.value
        return latestResult.epoch >= epoch && latestResult.succeeded
    }

    /// Invalidates foreground list reads that started before a mutation response.
    @discardableResult
    func advanceForegroundWorkspaceListMutationEpoch() -> UInt64 {
        foregroundWorkspaceListMutationEpoch &+= 1
        return foregroundWorkspaceListMutationEpoch
    }

    /// Records the newest mutation epoch represented by an installed list.
    func markForegroundWorkspaceListApplied() {
        foregroundWorkspaceListAppliedMutationEpoch = max(
            foregroundWorkspaceListAppliedMutationEpoch,
            foregroundWorkspaceListMutationEpoch
        )
    }
}
