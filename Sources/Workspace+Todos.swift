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
    /// the override expires as soon as the live signals change lanes. Picking
    /// a lane re-engages the feature (clears any None opt-out).
    func setTaskStatusOverride(_ status: WorkspaceTaskStatus) {
        todoState.statusHidden = false
        todoState.statusOverride = WorkspaceTaskStatusOverride(
            status: status,
            inferredAtOverride: inferredTaskStatus
        )
    }

    /// Returns the status to automatic by clearing the manual override (and
    /// any None opt-out), so the glyph shows the inferred lane again.
    func clearTaskStatusOverride() {
        todoState.statusHidden = false
        todoState.statusOverride = nil
    }

    /// Opts this workspace out of the status feature: no glyph is drawn before
    /// the title (the "None" state, distinct from Auto). Clears any override.
    func hideTaskStatus() {
        todoState.statusOverride = nil
        todoState.statusHidden = true
    }

    /// Cycles the effective status one lane forward (round-robin
    /// todo → working → needs-attention → review → done → todo) by pinning a
    /// manual override to the lane after the current effective status. Shared
    /// by the `cycleWorkspaceStatus` shortcut and `workspace.status.cycle`.
    func cycleTaskStatus() {
        setTaskStatusOverride(effectiveTaskStatus.next)
    }

    // MARK: - Checklist entry points (shared by socket, CLI, UI)

    /// Appends a checklist item (trims text, rejects empty, caps count and
    /// length per `WorkspaceChecklistItem` limits).
    func addChecklistItem(
        text: String,
        state: WorkspaceChecklistItem.State = .pending,
        origin: WorkspaceChecklistItem.Origin = .user,
        agentTaskRef: WorkspaceAgentTaskRef? = nil,
        dispatchTarget: WorkspaceTaskDispatchTarget? = nil,
        boundWorkspaceID: UUID? = nil,
        boundAgent: String? = nil,
        lastActivityAt: Date? = nil
    ) -> Result<WorkspaceChecklistItem, WorkspaceChecklistItem.AddError> {
        let result = notifyingChecklistCompletion {
            todoState.checklist.addChecklistItem(
                text,
                state: state,
                origin: origin,
                agentTaskRef: agentTaskRef,
                dispatchTarget: dispatchTarget,
                boundWorkspaceID: boundWorkspaceID,
                boundAgent: boundAgent,
                lastActivityAt: lastActivityAt ?? Date()
            )
        }
        if case .success = result { postTaskQueueChange() }
        return result
    }

    /// Binds a checklist item to a dispatched workspace and marks it active.
    /// This is the single mutation path used by queue dispatchers.
    @discardableResult
    func bindChecklistItem(
        id: UUID,
        toWorkspace workspaceID: UUID,
        agent: String?,
        at date: Date = Date()
    ) -> Bool {
        guard setChecklistItemState(id: id, state: .inProgress),
              let index = todoState.checklist.firstIndex(where: { $0.id == id }) else { return false }
        todoState.checklist[index].boundWorkspaceID = workspaceID
        todoState.checklist[index].boundAgent = agent
        todoState.checklist[index].lastActivityAt = date
        postTaskQueueChange()
        return true
    }

    /// Releases a checklist item whose dispatched workspace is no longer live.
    /// The dispatch target is retained so the item can be sent again.
    @discardableResult
    func clearChecklistItemBinding(
        id: UUID,
        at date: Date = Date()
    ) -> Bool {
        guard let index = todoState.checklist.firstIndex(where: { $0.id == id }),
              todoState.checklist[index].boundWorkspaceID != nil else { return false }
        todoState.checklist[index].boundWorkspaceID = nil
        todoState.checklist[index].boundAgent = nil
        if todoState.checklist[index].state == .inProgress {
            todoState.checklist[index].state = .pending
        }
        todoState.checklist[index].lastActivityAt = date
        postTaskQueueChange()
        return true
    }

    /// Sets or clears a task's dispatch target through the shared workspace
    /// mutation owner.
    @discardableResult
    func setChecklistItemDispatchTarget(
        id: UUID,
        target: WorkspaceTaskDispatchTarget?
    ) -> Bool {
        guard let index = todoState.checklist.firstIndex(where: { $0.id == id }) else { return false }
        todoState.checklist[index].dispatchTarget = target
        todoState.checklist[index].lastActivityAt = Date()
        postTaskQueueChange()
        return true
    }

    /// Sets one checklist item's state (keeping completed items last in
    /// storage; see `Array.setChecklistItemState`).
    ///
    /// - Returns: `true` if the item existed.
    @discardableResult
    func setChecklistItemState(id: UUID, state: WorkspaceChecklistItem.State) -> Bool {
        let changed = notifyingChecklistCompletion {
            todoState.checklist.setChecklistItemState(id: id, state: state)
        }
        if changed {
            touchChecklistItem(id: id)
            postTaskQueueChange()
        }
        return changed
    }

    /// Moves one checklist item toward a new 0-based position, staying within
    /// its completion partition (see `Array.moveChecklistItem`).
    ///
    /// - Returns: `true` if the item existed.
    @discardableResult
    func moveChecklistItem(id: UUID, toIndex: Int) -> Bool {
        let changed = todoState.checklist.moveChecklistItem(id: id, toIndex: toIndex)
        if changed {
            touchChecklistItem(id: id)
            postTaskQueueChange()
        }
        return changed
    }

    /// Rewrites one checklist item's text (same normalization as add).
    ///
    /// - Returns: `true` if the item existed and the text was non-empty.
    @discardableResult
    func setChecklistItemText(id: UUID, text: String) -> Bool {
        let changed = todoState.checklist.setChecklistItemText(id: id, text: text)
        if changed {
            touchChecklistItem(id: id)
            postTaskQueueChange()
        }
        return changed
    }

    /// Appends image attachment references to one checklist item.
    ///
    /// The referenced image files remain user-owned; removing checklist state
    /// deletes only these references, never the files on disk.
    @discardableResult
    func addChecklistAttachments(
        itemId: UUID,
        attachments: [WorkspaceChecklistAttachment]
    ) -> Bool {
        guard !attachments.isEmpty,
              let index = todoState.checklist.firstIndex(where: { $0.id == itemId }) else {
            return false
        }
        todoState.checklist[index].attachments.append(contentsOf: attachments)
        todoState.checklist[index].lastActivityAt = Date()
        postTaskQueueChange()
        return true
    }

    /// Removes one image attachment reference from one checklist item.
    ///
    /// - Returns: `true` if both the item and attachment reference existed.
    @discardableResult
    func removeChecklistAttachment(itemId: UUID, attachmentId: UUID) -> Bool {
        guard let itemIndex = todoState.checklist.firstIndex(where: { $0.id == itemId }),
              let attachmentIndex = todoState.checklist[itemIndex].attachments.firstIndex(where: { $0.id == attachmentId }) else {
            return false
        }
        todoState.checklist[itemIndex].attachments.remove(at: attachmentIndex)
        todoState.checklist[itemIndex].lastActivityAt = Date()
        postTaskQueueChange()
        return true
    }

    /// Removes one checklist item.
    ///
    /// - Returns: `true` if the item existed.
    @discardableResult
    func removeChecklistItem(id: UUID) -> Bool {
        let removed = notifyingChecklistCompletion {
            todoState.checklist.removeChecklistItem(id: id)
        }
        if removed { postTaskQueueChange() }
        return removed
    }

    /// Removes every checklist item.
    ///
    /// - Returns: The number of items removed.
    @discardableResult
    func clearChecklist() -> Int {
        let removed = todoState.checklist.clearChecklist()
        if removed > 0 { postTaskQueueChange() }
        return removed
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
        let result = notifyingChecklistCompletion {
            todoState.checklist.replaceChecklist(with: items)
        }
        if case .success = result { postTaskQueueChange() }
        return result
    }

    private func touchChecklistItem(id: UUID, at date: Date = Date()) {
        guard let index = todoState.checklist.firstIndex(where: { $0.id == id }) else { return }
        todoState.checklist[index].lastActivityAt = date
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
        hasher.combine(todoState.statusHidden)
        hasher.combine(todoState.checklist)
    }

    /// Restores the todo fields from a session snapshot (absent fields, e.g.
    /// from manifests written before this feature, restore to empty state).
    func restoreTodoState(from snapshot: SessionWorkspaceSnapshot) {
        todoState.statusOverride = snapshot.restoredTaskStatusOverride
        todoState.statusHidden = snapshot.taskStatusHidden ?? false
        todoState.checklist = snapshot.restoredChecklist
        postTaskQueueChange()
    }

    private func postTaskQueueChange() {
        NotificationCenter.default.post(
            name: .workspaceTaskQueueDidChange,
            object: nil,
            userInfo: ["workspaceId": id]
        )
    }
}
