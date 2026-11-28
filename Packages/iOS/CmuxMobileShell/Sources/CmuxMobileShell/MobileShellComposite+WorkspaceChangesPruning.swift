extension MobileShellComposite {
    func resetWorkspaceChangesState() {
        workspaceChangesSummaryDebounceTask?.cancel()
        workspaceChangesSummaryDebounceTask = nil
        workspaceChangesSummaryDebounceTaskID = nil
        workspaceChangesSummaryFetchTask?.cancel()
        workspaceChangesSummaryFetchTask = nil
        workspaceChangesSummaryFetchTaskID = nil
        workspaceChangesSummaryTrailingTask?.cancel()
        workspaceChangesSummaryTrailingTask = nil
        workspaceChangesSummaryTrailingTaskID = nil
        workspaceChangesSummaryTrailingDeadline = nil
        workspaceChangesSummaryTrailingExpiryByWorkspaceID = [:]
        workspaceChangesSummaryRefreshSchedulePolicy.reset()
        workspaceChangesSummaryLastEventAt = nil
        workspaceChangesSummaryFetchedAtByWorkspaceID = [:]
        setWorkspaceChangeChipsByWorkspaceID([:])
    }

    @discardableResult
    func pruneWorkspaceChangesSummaryStateToForeground()
        -> WorkspaceChangesSummaryWorkspaceSet {
        let workspaceSet = WorkspaceChangesSummaryWorkspaceSet(
            workspaceIDs: foregroundWorkspaceChangesIDs
        )
        workspaceChangesSummaryFetchedAtByWorkspaceID = workspaceSet.values(
            retaining: workspaceChangesSummaryFetchedAtByWorkspaceID
        )
        workspaceChangesSummaryTrailingExpiryByWorkspaceID = workspaceSet.values(
            retaining: workspaceChangesSummaryTrailingExpiryByWorkspaceID
        )
        workspaceChangesSummaryRefreshSchedulePolicy.retainWorkspaces(in: workspaceSet)
        let retainedChips = workspaceSet.values(
            retaining: workspaceChangeChipsByWorkspaceID
        )
        if retainedChips != workspaceChangeChipsByWorkspaceID {
            setWorkspaceChangeChipsByWorkspaceID(retainedChips)
        }
        return workspaceSet
    }

    func reconcileWorkspaceChangesSummaryStateWithForeground() {
        _ = pruneWorkspaceChangesSummaryStateToForeground()
        rescheduleWorkspaceChangesSummaryTrailingTask()
    }

    func evictWorkspaceChangesSummaryState(workspaceIDs: [String]) {
        guard !workspaceIDs.isEmpty else { return }
        let removedWorkspaceIDs = Set(workspaceIDs)
        workspaceChangesSummaryFetchedAtByWorkspaceID =
            workspaceChangesSummaryFetchedAtByWorkspaceID.filter {
                !removedWorkspaceIDs.contains($0.key)
            }
        workspaceChangesSummaryTrailingExpiryByWorkspaceID =
            workspaceChangesSummaryTrailingExpiryByWorkspaceID.filter {
                !removedWorkspaceIDs.contains($0.key)
            }
        let retainedWorkspaceSet = WorkspaceChangesSummaryWorkspaceSet(
            workspaceIDs: foregroundWorkspaceChangesIDs.filter {
                !removedWorkspaceIDs.contains($0)
            }
        )
        workspaceChangesSummaryRefreshSchedulePolicy.retainWorkspaces(
            in: retainedWorkspaceSet
        )
        let retainedChips = workspaceChangeChipsByWorkspaceID.filter {
            !removedWorkspaceIDs.contains($0.key)
        }
        if retainedChips != workspaceChangeChipsByWorkspaceID {
            setWorkspaceChangeChipsByWorkspaceID(retainedChips)
        }
        rescheduleWorkspaceChangesSummaryTrailingTask()
    }
}
