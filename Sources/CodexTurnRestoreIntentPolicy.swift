import CmuxWorkspaces
import Foundation
import CmuxWorkspaces

/// Preserves one Codex restore intent after a stale turn owner exits.
///
/// A completed or ordinary idle agent remains governed by the persisted
/// liveness gate. Only a hook-owned auto-resume binding with unfinished turn
/// state gets one more admission attempt; execution admission still rechecks
/// live ownership before launching anything.
enum CodexTurnRestoreIntentPolicy {
    static func shouldPreserveAfterOwnerExit(
        snapshot: SessionRestorableAgentSnapshot,
        binding: SurfaceResumeBindingSnapshot?,
        processLiveness: RestorableAgentProcessLiveness?
    ) -> Bool {
        snapshot.kind == .codex
            && snapshot.hadActivePromptTurn == true
            && binding?.isAgentHookBinding == true
            && binding?.autoResume == true
            && processLiveness == .exited
    }
}
