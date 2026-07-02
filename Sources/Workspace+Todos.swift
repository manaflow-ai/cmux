import CmuxSidebar
import CmuxWorkspaces
import Foundation

/// Workspace-level todo logic: sampling the live signals that drive
/// task-status inference, resolving the effective status against the manual
/// override, and the shared checklist mutation entry points used by the
/// socket verbs, the CLI, and the sidebar UI.
extension Workspace {
    // MARK: - Status signals

    /// Samples the live signals that drive task-status inference: agent
    /// lifecycle states (needs-input / running) for panels that still exist,
    /// the sidebar pull-request rows, and git working-tree dirtiness.
    func taskStatusSignals() -> WorkspaceTaskStatusSignals {
        var anyAgentNeedsInput = false
        var anyAgentRunning = false
        for (panelId, states) in agentLifecycleStatesByPanelId where panels[panelId] != nil {
            for state in states.values {
                if state == .needsInput { anyAgentNeedsInput = true }
                if state == .running { anyAgentRunning = true }
            }
        }
        let pullRequests = sidebarPullRequestsInDisplayOrder()
        return WorkspaceTaskStatusSignals(
            anyAgentNeedsInput: anyAgentNeedsInput,
            anyAgentRunning: anyAgentRunning,
            anyOpenPullRequest: pullRequests.contains { $0.status == .open },
            hasPullRequests: !pullRequests.isEmpty,
            allPullRequestsMergedOrClosed: !pullRequests.isEmpty
                && pullRequests.allSatisfy { $0.status != .open },
            isGitDirty: sidebarGitBranchesInDisplayOrder().contains { $0.isDirty }
        )
    }

    // MARK: - Status resolution

    /// The status inferred from the current live signals.
    var inferredTaskStatus: WorkspaceTaskStatus {
        WorkspaceTaskStatus.inferred(from: taskStatusSignals())
    }

    /// The status to display and report: the manual override while its
    /// recorded inference still matches, otherwise the live inference. Pure
    /// (never mutates state), so it is safe to read from view bodies; the
    /// expired-override cleanup happens in
    /// ``reconcileExpiredTaskStatusOverride()`` at mutation/read entry points.
    var effectiveTaskStatus: WorkspaceTaskStatus {
        WorkspaceTaskStatusOverride.effectiveStatus(
            override: todoState.statusOverride,
            inferred: inferredTaskStatus
        ).effective
    }

    /// Clears the stored override when the live inference has moved away from
    /// what it was at override time (anti-rot). Call from explicit entry
    /// points (socket verbs, CLI, user actions), never from view-body
    /// computations.
    func reconcileExpiredTaskStatusOverride() {
        guard WorkspaceTaskStatusOverride.effectiveStatus(
            override: todoState.statusOverride,
            inferred: inferredTaskStatus
        ).shouldClearOverride else { return }
        todoState.statusOverride = nil
    }

    /// Applies a manual status override, recording the current inference so
    /// the override expires as soon as the live signals change lanes.
    func setTaskStatusOverride(_ status: WorkspaceTaskStatus) {
        todoState.statusOverride = WorkspaceTaskStatusOverride(
            status: status,
            inferredAtOverride: inferredTaskStatus
        )
    }

    /// Returns the status to automatic by clearing the manual override.
    func clearTaskStatusOverride() {
        todoState.statusOverride = nil
    }

    // MARK: - Checklist entry points (shared by socket, CLI, UI)

    /// Appends a checklist item (trims text, rejects empty, caps count and
    /// length per `WorkspaceChecklistItem` limits).
    func addChecklistItem(
        text: String,
        state: WorkspaceChecklistItem.State = .pending,
        origin: WorkspaceChecklistItem.Origin = .user
    ) -> Result<WorkspaceChecklistItem, WorkspaceChecklistItem.AddError> {
        todoState.checklist.addChecklistItem(text, state: state, origin: origin)
    }

    /// Sets one checklist item's state.
    ///
    /// - Returns: `true` if the item existed.
    @discardableResult
    func setChecklistItemState(id: UUID, state: WorkspaceChecklistItem.State) -> Bool {
        todoState.checklist.setChecklistItemState(id: id, state: state)
    }

    /// Removes one checklist item.
    ///
    /// - Returns: `true` if the item existed.
    @discardableResult
    func removeChecklistItem(id: UUID) -> Bool {
        todoState.checklist.removeChecklistItem(id: id)
    }

    /// Removes every checklist item.
    ///
    /// - Returns: The number of items removed.
    @discardableResult
    func clearChecklist() -> Int {
        todoState.checklist.clearChecklist()
    }

    /// Atomically replaces the checklist, preserving identity (and origin)
    /// for incoming items whose id matches an existing item. See
    /// `Array.replaceChecklist(with:)` in CmuxWorkspaces for the merge rules.
    ///
    /// - Parameter items: The full desired checklist.
    /// - Returns: The resulting checklist, or the rejection reason (nothing
    ///   is mutated on rejection).
    @discardableResult
    func replaceChecklist(
        with items: [WorkspaceChecklistReplacementItem]
    ) -> Result<[WorkspaceChecklistItem], WorkspaceChecklistReplaceError> {
        todoState.checklist.replaceChecklist(with: items)
    }

    /// The checklist item at a 0-based display index, if in bounds.
    func checklistItem(atIndex index: Int) -> WorkspaceChecklistItem? {
        guard todoState.checklist.indices.contains(index) else { return nil }
        return todoState.checklist[index]
    }

    /// The checklist progress readout (completed/total, first unchecked).
    var checklistProgressSummary: WorkspaceChecklistProgressSummary {
        todoState.checklist.checklistProgressSummary
    }

    // MARK: - Session persistence

    /// Folds the persisted todo fields into the session-autosave fingerprint
    /// so an override or checklist change triggers a save.
    func combineTodoStateIntoSessionAutosaveFingerprint(into hasher: inout Hasher) {
        hasher.combine(todoState.statusOverride)
        hasher.combine(todoState.checklist)
    }

    /// Restores the todo fields from a session snapshot (absent fields, e.g.
    /// from manifests written before this feature, restore to empty state).
    func restoreTodoState(from snapshot: SessionWorkspaceSnapshot) {
        todoState.statusOverride = snapshot.restoredTaskStatusOverride
        todoState.checklist = snapshot.restoredChecklist
    }
}
