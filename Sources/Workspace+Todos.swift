import CmuxSidebar
import CmuxWorkspaces
import Foundation

/// The status inputs that are owned by a workspace rather than by its sidebar
/// presentation cache. Updates are duplicate-filtered and delivered through a
/// bounded stream so every consumer sees the same live transition.
@MainActor
final class WorkspaceTaskStatusSignalOwner {
    private(set) var signals = WorkspaceTaskStatusSignals()

    private var agentLifecycleStatesByPanelId: [UUID: [String: AgentHibernationLifecycleState]] = [:]
    private var panelGitBranches: [UUID: SidebarGitBranchState] = [:]
    private var panelPullRequests: [UUID: SidebarPullRequestState] = [:]
    private var workspaceGitBranch: SidebarGitBranchState?
    private var workspacePullRequest: SidebarPullRequestState?
    private var observers: [UUID: AsyncStream<WorkspaceTaskStatusSignals>.Continuation] = [:]

    /// Emits the current signal sample immediately, then every distinct sample.
    func changes() -> AsyncStream<WorkspaceTaskStatusSignals> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            observers[id] = continuation
            continuation.yield(signals)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.observers[id] = nil }
            }
        }
    }

    /// Replaces agent lifecycle inputs, dropping entries for panels that no longer exist.
    @discardableResult
    func setAgentLifecycleStates(
        _ states: [UUID: [String: AgentHibernationLifecycleState]],
        validPanelIds: Set<UUID>
    ) -> WorkspaceTaskStatusSignalTransition {
        agentLifecycleStatesByPanelId = states.filter { validPanelIds.contains($0.key) }
        return recomputeSignals()
    }

    /// Records a panel's structured git state independently of sidebar visibility settings.
    @discardableResult
    func setPanelGitBranch(
        _ state: SidebarGitBranchState?,
        panelId: UUID
    ) -> WorkspaceTaskStatusSignalTransition {
        let previous = panelGitBranches[panelId]
        if let state {
            panelGitBranches[panelId] = state
        } else {
            panelGitBranches.removeValue(forKey: panelId)
        }
        if previous?.branch != state?.branch {
            panelPullRequests.removeValue(forKey: panelId)
        }
        return recomputeSignals()
    }

    /// Records the workspace-level git fallback used when no panel has a branch.
    @discardableResult
    func setWorkspaceGitBranch(_ state: SidebarGitBranchState?) -> WorkspaceTaskStatusSignalTransition {
        workspaceGitBranch = state
        return recomputeSignals()
    }

    /// Records a panel pull request independently of whether its badge is rendered.
    @discardableResult
    func setPanelPullRequest(
        _ state: SidebarPullRequestState?,
        panelId: UUID
    ) -> WorkspaceTaskStatusSignalTransition {
        if let state {
            panelPullRequests[panelId] = state
        } else {
            panelPullRequests.removeValue(forKey: panelId)
        }
        return recomputeSignals()
    }

    /// Records the workspace-level pull-request fallback.
    @discardableResult
    func setWorkspacePullRequest(_ state: SidebarPullRequestState?) -> WorkspaceTaskStatusSignalTransition {
        workspacePullRequest = state
        return recomputeSignals()
    }

    /// Seeds restored git state without treating session restoration as a user-visible transition.
    func restoreGitState(
        workspaceBranch: SidebarGitBranchState?,
        panelBranches: [UUID: SidebarGitBranchState],
        validPanelIds: Set<UUID>
    ) {
        workspaceGitBranch = workspaceBranch
        panelGitBranches = panelBranches.filter { validPanelIds.contains($0.key) }
        _ = recomputeSignals(emit: false)
    }

    /// Removes all signal inputs for a panel that left the workspace.
    @discardableResult
    func removePanel(_ panelId: UUID) -> WorkspaceTaskStatusSignalTransition {
        agentLifecycleStatesByPanelId.removeValue(forKey: panelId)
        panelGitBranches.removeValue(forKey: panelId)
        panelPullRequests.removeValue(forKey: panelId)
        return recomputeSignals()
    }

    /// Drops signal inputs for panels that are no longer present after topology pruning.
    @discardableResult
    func prunePanels(validPanelIds: Set<UUID>) -> WorkspaceTaskStatusSignalTransition {
        agentLifecycleStatesByPanelId = agentLifecycleStatesByPanelId.filter { validPanelIds.contains($0.key) }
        panelGitBranches = panelGitBranches.filter { validPanelIds.contains($0.key) }
        panelPullRequests = panelPullRequests.filter { validPanelIds.contains($0.key) }
        return recomputeSignals()
    }

    /// Clears all signal inputs when the workspace changes repository context.
    @discardableResult
    func reset() -> WorkspaceTaskStatusSignalTransition {
        agentLifecycleStatesByPanelId.removeAll()
        panelGitBranches.removeAll()
        panelPullRequests.removeAll()
        workspaceGitBranch = nil
        workspacePullRequest = nil
        return recomputeSignals()
    }

    private func recomputeSignals(emit: Bool = true) -> WorkspaceTaskStatusSignalTransition {
        let pullRequests = Array(panelPullRequests.values) + (workspacePullRequest.map { [$0] } ?? [])
        let branches = Array(panelGitBranches.values) + (workspaceGitBranch.map { [$0] } ?? [])
        let next = WorkspaceTaskStatusSignals(
            anyAgentNeedsInput: agentLifecycleStatesByPanelId.values.contains { states in
                states.values.contains(.needsInput)
            },
            anyAgentRunning: agentLifecycleStatesByPanelId.values.contains { states in
                states.values.contains(.running)
            },
            anyOpenPullRequest: pullRequests.contains { $0.status == .open },
            hasPullRequests: !pullRequests.isEmpty,
            allPullRequestsMergedOrClosed: !pullRequests.isEmpty
                && pullRequests.allSatisfy { $0.status != .open },
            isGitDirty: branches.contains { $0.isDirty }
        )
        let transition = WorkspaceTaskStatusSignalTransition(
            previous: signals,
            current: next
        )
        guard transition.didChange else { return transition }
        signals = next
        guard emit else { return transition }
        var terminatedObserverIds: [UUID] = []
        for (id, observer) in observers {
            if case .terminated = observer.yield(next) {
                terminatedObserverIds.append(id)
            }
        }
        for id in terminatedObserverIds {
            observers[id] = nil
        }
        return transition
    }
}

/// The before/after sample produced by one workspace status-signal mutation.
struct WorkspaceTaskStatusSignalTransition: Equatable {
    let previous: WorkspaceTaskStatusSignals
    let current: WorkspaceTaskStatusSignals

    var didChange: Bool { previous != current }

    var previousStatus: WorkspaceTaskStatus {
        WorkspaceTaskStatus.inferred(from: previous)
    }

    var currentStatus: WorkspaceTaskStatus {
        WorkspaceTaskStatus.inferred(from: current)
    }
}

/// Workspace-level todo logic: sampling the live signals that drive
/// task-status inference, resolving the effective status against the manual
/// override, and the shared checklist mutation entry points used by the
/// socket verbs, the CLI, and the sidebar UI.
extension Workspace {
    // MARK: - Status signals

    /// Returns the authoritative live signal sample owned by this workspace.
    func taskStatusSignals(orderedPanelIds: [UUID]? = nil) -> WorkspaceTaskStatusSignals {
        taskStatusSignalOwner.signals
    }

    /// Applies one signal-owner transition to the shared lifecycle rules.
    /// Override expiry and inferred-done notifications therefore run for
    /// agent, Git, and pull-request updates through the same path.
    func handleTaskStatusSignalTransition(_ transition: WorkspaceTaskStatusSignalTransition) {
        guard transition.didChange else { return }
        reconcileExpiredTaskStatusOverride()
        guard transition.previousStatus != .done,
              transition.currentStatus == .done else { return }
        postInferredDoneNotification()
    }

    // MARK: - Status resolution

    /// The status inferred from the current live signals.
    var inferredTaskStatus: WorkspaceTaskStatus {
        WorkspaceTaskStatus.inferred(from: taskStatusSignals())
    }

    /// The status to display and report: the manual override while its
    /// recorded inference still matches, otherwise the live inference. Pure
    /// (never mutates state), so it is safe to read from view bodies; the
    /// signal owner clears expired overrides at the live-signal boundary.
    var effectiveTaskStatus: WorkspaceTaskStatus {
        WorkspaceTaskStatusOverride.effectiveStatus(
            override: todoState.statusOverride,
            inferred: inferredTaskStatus
        ).effective
    }

    /// Clears the stored override when the live inference has moved away from
    /// what it was at override time (anti-rot).
    func reconcileExpiredTaskStatusOverride() {
        guard WorkspaceTaskStatusOverride.effectiveStatus(
            override: todoState.statusOverride,
            inferred: inferredTaskStatus
        ).shouldClearOverride else { return }
        todoState.statusOverride = nil
        persistTodoState()
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
        persistTodoState()
    }

    /// Returns the status to automatic by clearing the manual override (and
    /// any None opt-out), so the glyph shows the inferred lane again.
    func clearTaskStatusOverride() {
        todoState.statusHidden = false
        todoState.statusOverride = nil
        persistTodoState()
    }

    /// Opts this workspace out of the status feature: no glyph is drawn before
    /// the title (the "None" state, distinct from Auto). Clears any override.
    func hideTaskStatus() {
        todoState.statusOverride = nil
        todoState.statusHidden = true
        persistTodoState()
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
        origin: WorkspaceChecklistItem.Origin = .user
    ) -> Result<WorkspaceChecklistItem, WorkspaceChecklistItem.AddError> {
        let result = notifyingChecklistCompletion {
            todoState.checklist.addChecklistItem(text, state: state, origin: origin)
        }
        if case .success = result {
            persistTodoState()
        }
        return result
    }

    /// Sets one checklist item's state (keeping completed items last in
    /// storage; see `Array.setChecklistItemState`).
    ///
    /// - Returns: `true` if the item existed.
    @discardableResult
    func setChecklistItemState(id: UUID, state: WorkspaceChecklistItem.State) -> Bool {
        let didSet = notifyingChecklistCompletion {
            todoState.checklist.setChecklistItemState(id: id, state: state)
        }
        if didSet {
            persistTodoState()
        }
        return didSet
    }

    /// Moves one checklist item toward a new 0-based position, staying within
    /// its completion partition (see `Array.moveChecklistItem`).
    ///
    /// - Returns: `true` if the item existed.
    @discardableResult
    func moveChecklistItem(id: UUID, toIndex: Int) -> Bool {
        let didMove = todoState.checklist.moveChecklistItem(id: id, toIndex: toIndex)
        if didMove {
            persistTodoState()
        }
        return didMove
    }

    /// Rewrites one checklist item's text (same normalization as add).
    ///
    /// - Returns: `true` if the item existed and the text was non-empty.
    @discardableResult
    func setChecklistItemText(id: UUID, text: String) -> Bool {
        let didSet = todoState.checklist.setChecklistItemText(id: id, text: text)
        if didSet {
            persistTodoState()
        }
        return didSet
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
        persistTodoState()
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
        persistTodoState()
        return true
    }

    /// Removes one checklist item.
    ///
    /// - Returns: `true` if the item existed.
    @discardableResult
    func removeChecklistItem(id: UUID) -> Bool {
        let didRemove = notifyingChecklistCompletion {
            todoState.checklist.removeChecklistItem(id: id)
        }
        if didRemove {
            persistTodoState()
        }
        return didRemove
    }

    /// Removes every checklist item.
    ///
    /// - Returns: The number of items removed.
    @discardableResult
    func clearChecklist() -> Int {
        let removedCount = todoState.checklist.clearChecklist()
        if removedCount > 0 {
            persistTodoState()
        }
        return removedCount
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
        if case .success = result {
            persistTodoState()
        }
        return result
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
    }

    /// All callers, including CLI and UI edits, use the session persistence owner.
    private func persistTodoState() {
        AppDelegate.shared?.saveTodoState(in: self)
    }
}
