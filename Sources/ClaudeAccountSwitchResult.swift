import CMUXAgentLaunch

/// How a request to move a Claude pane to another account ended.
enum ClaudeAccountSwitchResult: Equatable, Sendable {
    /// The pane respawned on the target account, its shell reached a prompt, and the resume
    /// command was typed into it.
    case switched(ClaudeAccountSwitchPlan, ClaudeTranscriptAccountSyncOutcome)
    /// The pane respawned on the target account and the transcript is there, but the resume
    /// command was never typed: the pane was closed or replaced, or its new shell did not
    /// report a prompt in time. The pane may sit at a bare shell, so callers hand the user the
    /// built resume command from the ``ClaudeAccountSwitchManualResume``.
    case switchedWithoutResume(
        ClaudeAccountSwitchPlan,
        ClaudeTranscriptAccountSyncOutcome,
        ClaudeAccountSwitchManualResume
    )
    /// The planner refused the switch; nothing changed. A session cmux cannot confirm or
    /// resume also lands here as ``ClaudeAccountSwitchRefusal/noClaudeSession``.
    case refused(ClaudeAccountSwitchRefusal)
    /// The pane is not running a Claude session.
    case notClaude
    /// The pane runs on another machine (SSH, cloud or remote tmux).
    case remoteUnsupported
    /// A switch for this pane is already in progress.
    case alreadySwitching
    /// The transcript could not be made available to the target account; the pane was left
    /// alone so a fresh conversation never replaces it.
    case transcriptUnavailable
    /// The terminal surface could not be replaced; the pane was left alone.
    case respawnFailed
}
