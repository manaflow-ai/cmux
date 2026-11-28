import CMUXAgentLaunch

/// How a request to move a Claude pane to another account ended.
enum ClaudeAccountSwitchResult: Equatable, Sendable {
    /// The pane respawned on the target account, its shell reached a prompt, and the resume
    /// command was typed into it.
    case switched(ClaudeAccountSwitchPlan, ClaudeTranscriptAccountSyncOutcome)
    /// The pane respawned on the target account and the transcript is there, but the resume
    /// command was never typed: the pane was closed or replaced, its new shell did not report a
    /// prompt in time, the replaced Claude was still running, or the transcript could not be
    /// copied again after that Claude quit. The pane may sit at a bare
    /// shell, so callers hand the user the built resume command from the
    /// ``ClaudeAccountSwitchManualResume``, whose `reason` says which.
    case switchedWithoutResume(
        ClaudeAccountSwitchPlan,
        ClaudeTranscriptAccountSyncOutcome,
        ClaudeAccountSwitchManualResume
    )
    /// The planner refused the switch; nothing changed. A session cmux cannot confirm or
    /// resume also lands here as ``ClaudeAccountSwitchRefusal/noClaudeSession``, and one with
    /// no conversation to resume yet as ``ClaudeAccountSwitchRefusal/noConversationYet``.
    case refused(ClaudeAccountSwitchRefusal)
    /// The pane is not running a Claude session.
    case notClaude
    /// The pane runs on another machine (SSH, cloud or remote tmux).
    case remoteUnsupported
    /// The session's Claude runs on a terminal other than the pane's (inside tmux or screen, or
    /// in another terminal or cmux pane) or on none (detached), so restarting the pane would not
    /// stop it and the session would run in two places. Nothing changed.
    case agentNotOwnedByPane
    /// A switch for this pane is already in progress.
    case alreadySwitching
    /// Claude was responding right before the pane would have restarted, and the caller had not
    /// agreed to stop a response: it started while the switch prepared. Nothing changed.
    case agentRunning
    /// The agent-index scan that names the Claude processes running the session failed or timed
    /// out, so cmux could not confirm the restart would stop them. Nothing changed.
    case agentIndexUnavailable
    /// The transcript could not be made available to the target account; the pane was left
    /// alone so a fresh conversation never replaces it.
    case transcriptUnavailable
    /// The terminal surface could not be replaced; the pane was left alone.
    case respawnFailed
}
