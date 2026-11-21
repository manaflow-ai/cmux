import CMUXAgentLaunch
import Foundation

/// Mutation entry points for the workspace's session priority state. Each
/// ignores a no-op change, otherwise persists and tells the coordinator.
///
/// `Workspace` is main-actor isolated (inferred from its `FilePreviewTabMetadataHost`
/// conformance), as is the `SessionPriorityWorkspaceState` these touch; the extension
/// states that boundary instead of leaving it to the inference.
@MainActor
extension Workspace {
    /// Sets or clears (nil = automatic) the user's difficulty override.
    func setClaudeDifficultyOverride(_ difficulty: ClaudeSessionDifficulty?) {
        guard sessionPriorityState.difficultyOverride != difficulty else { return }
        sessionPriorityState.difficultyOverride = difficulty
        sendSessionPriorityDidChange()
        sessionPriorityStateDidChange()
    }

    /// Records the difficulty assessed at a turn end.
    func setAutoClaudeDifficulty(_ difficulty: ClaudeSessionDifficulty) {
        guard sessionPriorityState.autoDifficulty != difficulty else { return }
        sessionPriorityState.autoDifficulty = difficulty
        sessionPriorityStateDidChange()
    }

    /// Opts this workspace in or out of automatic effort adjustment. Opting in
    /// ("adjust automatically") also lifts a `/effort` or `/model` cmux saw on
    /// one of its panes, even when the workspace was not marked manual.
    func setSessionPriorityManual(_ on: Bool) {
        if !on { SessionPriorityCoordinatorHook.adjustAutomaticallyRequested?(id) }
        guard sessionPriorityState.isManual != on else { return }
        sessionPriorityState.isManual = on
        sendSessionPriorityDidChange()
        sessionPriorityStateDidChange()
    }

    // MARK: - Session persistence

    /// Folds the persisted fields into the session-autosave fingerprint.
    func combineSessionPriorityStateIntoSessionAutosaveFingerprint(into hasher: inout Hasher) {
        hasher.combine(sessionPriorityState.difficultyOverride)
        hasher.combine(sessionPriorityState.autoDifficulty)
        hasher.combine(sessionPriorityState.isManual)
    }

    /// Restores from a snapshot; absent or unknown values restore to the default.
    func restoreSessionPriorityState(from snapshot: SessionWorkspaceSnapshot) {
        let state = sessionPriorityState
        let before = (state.difficultyOverride, state.isManual)
        state.difficultyOverride = snapshot.restoredClaudeDifficultyOverride
        state.autoDifficulty = snapshot.restoredClaudeDifficultyAuto
        state.isManual = snapshot.sessionPriorityManual ?? false
        if before != (state.difficultyOverride, state.isManual) {
            sendSessionPriorityDidChange()
        }
    }

    private func sessionPriorityStateDidChange() {
        // Shares the generic session autosave with the todo edits (historical name).
        AppDelegate.shared?.saveTodoState(in: self)
        SessionPriorityCoordinatorHook.workspaceStateDidChange?(id)
    }

    /// The sidebar row's change event for the values it freezes into its context menu (the
    /// override and the manual flag), sent once the new values are in place.
    private func sendSessionPriorityDidChange() {
        sessionPriorityDidChangeSubject.send(sessionPriorityDidChangeSubject.value &+ 1)
    }
}
