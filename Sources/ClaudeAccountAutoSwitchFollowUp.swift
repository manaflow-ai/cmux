import CMUXAgentLaunch
import Foundation

/// What an automatic switch does once ``Workspace/switchClaudeAccount(panelId:toAccountNamed:trigger:stopsRunningResponse:paneIsFree:)``
/// returns. Only a switch whose resume was typed may go on to type `continue`.
enum ClaudeAccountAutoSwitchFollowUp: Equatable, Sendable {
    /// The conversation `sessionId` resumed on `to`. Announce the switch; when `typeContinue`,
    /// type `continue` once that session's Claude waits at an empty prompt (see
    /// ``ClaudeAccountAutoSwitchContinueGate``).
    case announce(from: String, to: String, sessionId: String, typeContinue: Bool)
    /// The pane moved to `to` but cmux never typed the resume command. Announce the switch and
    /// post `notification`, the manual-resume notification the socket path posts; never type
    /// anything.
    case announceWithoutResume(from: String, to: String, notification: ClaudeAccountSwitchSocketOutcome.ResumeNotification?)
    /// Nothing switched. The pane keeps its usage-limit status and the target account is not
    /// marked exhausted.
    case keepUsageLimitStatus
    /// Nothing switched because the pane was in use right before it would have restarted: tell
    /// the user, as a hold-back does.
    case paneInUse

    /// A fixed name for debug logs. It names no account or session.
    var logName: String {
        switch self {
        case .announce(_, _, _, let typeContinue):
            return typeContinue ? "announce.continue" : "announce"
        case .announceWithoutResume:
            return "announceWithoutResume"
        case .keepUsageLimitStatus:
            return "keepUsageLimitStatus"
        case .paneInUse:
            return "paneInUse"
        }
    }

    /// The follow-up for `result`.
    ///
    /// - Parameters:
    ///   - result: What the switch returned.
    ///   - sendContinue: Whether the target account trusts the session's folder.
    ///   - paneClosed: Whether the pane closed while the switch ran. The close cancels the switch's
    ///     run and cuts its waits short, so `result` can blame what the close caused: a pane that
    ///     read as in use while it closed, or a resume withheld for a Claude still exiting or a
    ///     prompt that never came. The closed pane then gets no hold-back notice, and a resume left
    ///     to the user names the closed pane. A failed transcript copy keeps its own notice: the
    ///     copy may miss the replaced Claude's last messages either way, and that notice names no
    ///     button.
    init(result: ClaudeAccountSwitchResult, sendContinue: Bool, paneClosed: Bool = false) {
        switch result {
        case .switched(let plan, _):
            self = .announce(from: plan.source.name, to: plan.target.name, sessionId: plan.sessionID, typeContinue: sendContinue)
        case .switchedWithoutResume(let plan, let outcome, let manualResume):
            let reported = paneClosed && manualResume.reason != .transcriptResyncFailed
                ? ClaudeAccountSwitchManualResume(
                    command: manualResume.command,
                    typedInput: manualResume.typedInput,
                    reason: .paneReplaced
                )
                : manualResume
            self = .announceWithoutResume(
                from: plan.source.name,
                to: plan.target.name,
                notification: ClaudeAccountSwitchSocketOutcome
                    .finished(.switchedWithoutResume(plan, outcome, reported))
                    .resumeNotification
            )
        case .refused, .notClaude, .remoteUnsupported, .agentNotOwnedByPane, .alreadySwitching,
             .agentRunning, .agentIndexUnavailable, .transcriptUnavailable, .respawnFailed:
            self = .keepUsageLimitStatus
        case .paneInUse:
            self = paneClosed ? .keepUsageLimitStatus : .paneInUse
        }
    }
}
