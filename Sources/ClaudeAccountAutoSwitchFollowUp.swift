import CMUXAgentLaunch
import Foundation

/// What an automatic switch does once ``Workspace/switchClaudeAccount(panelId:toAccountNamed:trigger:)``
/// returns. Only a switch whose resume was typed may go on to type `continue`.
enum ClaudeAccountAutoSwitchFollowUp: Equatable, Sendable {
    /// The conversation `sessionId` resumed on `to`. Announce the switch; when `typeContinue`,
    /// type `continue` once that session's Claude waits at an empty prompt (see
    /// ``ClaudeAccountAutoSwitchContinueGate``).
    case announce(from: String, to: String, sessionId: String, typeContinue: Bool)
    /// The pane moved to `to` but cmux never typed the resume command. Announce the switch and
    /// post the manual-resume notification the socket path posts; never type anything.
    case announceWithoutResume(from: String, to: String)
    /// Nothing switched. The pane keeps its usage-limit status and the target account is not
    /// marked exhausted.
    case keepUsageLimitStatus
    /// Nothing switched because the pane was in use right before it would have restarted: tell
    /// the user, as a hold-back does.
    case paneInUse

    /// The follow-up for `result`.
    ///
    /// - Parameters:
    ///   - result: What the switch returned.
    ///   - sendContinue: Whether the target account trusts the session's folder.
    init(result: ClaudeAccountSwitchResult, sendContinue: Bool) {
        switch result {
        case .switched(let plan, _):
            self = .announce(from: plan.source.name, to: plan.target.name, sessionId: plan.sessionID, typeContinue: sendContinue)
        case .switchedWithoutResume(let plan, _, _):
            self = .announceWithoutResume(from: plan.source.name, to: plan.target.name)
        case .refused, .notClaude, .remoteUnsupported, .agentNotOwnedByPane, .alreadySwitching,
             .transcriptUnavailable, .respawnFailed:
            self = .keepUsageLimitStatus
        case .paneInUse:
            self = .paneInUse
        }
    }
}
