import CmuxWorkspaces
import Foundation

/// One terminal restore transaction waiting for its topology owner to commit.
struct PendingTerminalStartupRestore {
    let panel: TerminalPanel
    /// Owner at staging time, before a cross-topology adoption can retarget the panel.
    let stagedWorkspaceID: UUID
    let snapshot: SessionRestorableAgentSnapshot?
    let manualResumeAvailable: Bool
    let willRunStartupCommand: Bool
    let willRunStartupInput: Bool
    let resumeWorkingDirectory: String?
    let chatResumeBinding: PendingTerminalStartupRestoreChatBinding?
    let ownedResumeLaunchClaim: SessionRestorableAgentSnapshot?

    var willRunStartupWork: Bool {
        willRunStartupCommand || willRunStartupInput
    }
}
