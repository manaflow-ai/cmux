/// How applying a session priority target to a pane ended.
enum SessionPriorityApplyResult: Equatable, Sendable {
    /// The pane restarted and `claude --resume` with the target was typed into it.
    case applied(sessionID: String)
    /// The pane was busy; nothing changed.
    case held(SessionPriorityApplyGate.HoldReason)
    /// The pane cannot take the target; nothing changed.
    case refused(Refusal)
    /// The pane could not be restarted; nothing changed.
    case respawnFailed
    /// The pane restarted but the resume was not typed. It holds the command to run by hand.
    case resumeNotTyped(ClaudeAccountSwitchManualResume)

    /// Why a pane cannot take the target.
    enum Refusal: String, Sendable {
        /// The pane has no Claude session.
        case notClaude
        /// The pane runs on another machine.
        case remoteUnsupported
        /// cmux cannot confirm the pane's live Claude session, or cannot build its resume.
        case noClaudeSession
        /// The session has no working directory to resume in.
        case missingWorkingDirectory
        /// Nobody has sent the session a message, so there is nothing to resume.
        case noConversationYet
        /// The pane's restart would not stop its Claude (inside tmux or screen, or detached).
        case agentNotOwnedByPane
        /// The pane is already being restarted for a target.
        case alreadyApplying
    }
}

#if DEBUG
extension SessionPriorityApplyResult {
    /// A short form for debug logs. It never includes the resume command.
    var debugSummary: String {
        switch self {
        case .applied: return "applied"
        case .held(let reason): return "held.\(reason.rawValue)"
        case .refused(let refusal): return "refused.\(refusal.rawValue)"
        case .respawnFailed: return "respawnFailed"
        case .resumeNotTyped(let manual): return "resumeNotTyped.\(manual.reason)"
        }
    }
}
#endif
