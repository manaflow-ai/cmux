import CMUXAgentLaunch

/// How a request to move a Claude pane to another account ended.
enum ClaudeAccountSwitchResult: Equatable, Sendable {
    /// The pane respawned on the target account and the resume command was queued.
    case switched(ClaudeAccountSwitchPlan, ClaudeTranscriptAccountSyncOutcome)
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
