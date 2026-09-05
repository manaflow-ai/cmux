extension MobileShellComposite {
    /// Cancel in-flight workspace-changes summary fetches on a transient
    /// disconnect WITHOUT discarding the last-known chips or the reuse-window
    /// cache.
    ///
    /// Wiping the chips on every disconnect dropped each workspace's
    /// `filesChanged` to zero, and the reconnect refetch restored it — that
    /// `N -> 0 -> N` churn re-presented the files-changed hint (and re-showed
    /// the toolbar chip) on every reconnect cycle (issue #10482). Chips for
    /// workspaces that actually left the list are still pruned by
    /// ``pruneWorkspaceChangesSummaryStateToForeground()`` /
    /// ``evictWorkspaceChangesSummaryState(workspaceIDs:)`` when the workspace
    /// list changes, and a host that stops advertising the capability clears
    /// them through the full ``resetWorkspaceChangesState()``.
    func suspendWorkspaceChangesSummaryFetchesPreservingChips() {
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
    }

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
