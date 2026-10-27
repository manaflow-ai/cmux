import CMUXAgentLaunch
import Foundation

/// Mutation entry points for the workspace's session priority state. Each
/// ignores a no-op change, otherwise persists and tells the coordinator.
extension Workspace {
    /// Sets or clears (nil = automatic) the user's difficulty override.
    func setClaudeDifficultyOverride(_ difficulty: ClaudeSessionDifficulty?) {
        guard sessionPriorityState.difficultyOverride != difficulty else { return }
        sessionPriorityState.difficultyOverride = difficulty
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
        sessionPriorityState.difficultyOverride = snapshot.restoredClaudeDifficultyOverride
        sessionPriorityState.autoDifficulty = snapshot.restoredClaudeDifficultyAuto
        sessionPriorityState.isManual = snapshot.sessionPriorityManual ?? false
    }

    private func sessionPriorityStateDidChange() {
        // Shares the generic session autosave with the todo edits (historical name).
        AppDelegate.shared?.saveTodoState(in: self)
        SessionPriorityCoordinatorHook.workspaceStateDidChange?(id)
    }
}
