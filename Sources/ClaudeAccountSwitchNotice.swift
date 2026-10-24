import CMUXAgentLaunch
import Foundation

/// What the user is told after a Claude account switch that did not end with the conversation
/// resumed on the new account. One case per way a switch can fall short.
enum ClaudeAccountSwitchNotice: Equatable, Sendable {
    /// The pane now runs on `accountName`, but the resume command was never typed, so the user
    /// resumes `sessionID` by hand.
    case resumeManually(accountName: String, sessionID: String)
    /// No registered account has this name.
    case unknownAccount(String)
    /// The pane already runs on this account.
    case alreadyOnAccount(String)
    /// cmux could not confirm or resume the pane's Claude conversation.
    case noClaudeSession
    /// The conversation's working directory is unknown.
    case missingWorkingDirectory
    /// The pane is not running Claude.
    case notClaude
    /// The pane runs on another machine.
    case remoteUnsupported
    /// A switch for the pane is already in progress.
    case alreadySwitching
    /// The transcript could not be made available to `accountName`; the pane was left alone.
    case transcriptUnavailable(accountName: String)
    /// The terminal could not be restarted; the pane was left alone.
    case respawnFailed

    /// The notice for `result`, or `nil` when the conversation resumed on the new account.
    ///
    /// - Parameters:
    ///   - result: What ``Workspace/switchClaudeAccount(panelId:toAccountNamed:trigger:)`` returned.
    ///   - requestedAccountName: The account the user picked, named by results that carry no plan.
    init?(result: ClaudeAccountSwitchResult, requestedAccountName: String) {
        switch result {
        case .switched:
            return nil
        case .switchedWithoutResume(let plan, _):
            self = .resumeManually(accountName: plan.target.name, sessionID: plan.sessionID)
        case .refused(.noClaudeSession):
            self = .noClaudeSession
        case .refused(.missingWorkingDirectory):
            self = .missingWorkingDirectory
        case .refused(.unknownAccount(let name)):
            self = .unknownAccount(name)
        case .refused(.sameAccount(let name)):
            self = .alreadyOnAccount(name)
        case .notClaude:
            self = .notClaude
        case .remoteUnsupported:
            self = .remoteUnsupported
        case .alreadySwitching:
            self = .alreadySwitching
        case .transcriptUnavailable:
            self = .transcriptUnavailable(accountName: requestedAccountName)
        case .respawnFailed:
            self = .respawnFailed
        }
    }

    /// Whether the switch failed and the pane was left as it was.
    var reportsFailure: Bool {
        if case .resumeManually = self { return false }
        return true
    }

    /// The alert's headline.
    var title: String {
        switch self {
        case .resumeManually(let accountName, _):
            return String(
                format: String(
                    localized: "dialog.claudeAccountSwitch.resumeManually.title",
                    defaultValue: "Switched to %@"
                ),
                accountName
            )
        default:
            return String(
                localized: "dialog.claudeAccountSwitch.failed.title",
                defaultValue: "Couldn't Switch Claude Account"
            )
        }
    }

    /// The alert's explanation.
    var message: String {
        switch self {
        case .resumeManually(_, let sessionID):
            return String(
                format: String(
                    localized: "dialog.claudeAccountSwitch.resumeManually.message",
                    defaultValue: "cmux couldn't resume the conversation automatically. To continue it, run claude --resume %@ in this terminal."
                ),
                sessionID
            )
        case .unknownAccount(let name):
            return String(
                format: String(
                    localized: "dialog.claudeAccountSwitch.unknownAccount.message",
                    defaultValue: "No Claude account named %@ is registered."
                ),
                name
            )
        case .alreadyOnAccount(let name):
            return String(
                format: String(
                    localized: "dialog.claudeAccountSwitch.sameAccount.message",
                    defaultValue: "This terminal already uses the %@ account."
                ),
                name
            )
        case .noClaudeSession:
            return String(
                localized: "dialog.claudeAccountSwitch.noClaudeSession.message",
                defaultValue: "cmux couldn't find a Claude conversation to continue in this terminal."
            )
        case .missingWorkingDirectory:
            return String(
                localized: "dialog.claudeAccountSwitch.missingWorkingDirectory.message",
                defaultValue: "cmux couldn't find the working directory of this Claude conversation."
            )
        case .notClaude:
            return String(
                localized: "dialog.claudeAccountSwitch.notClaude.message",
                defaultValue: "This terminal isn't running Claude Code."
            )
        case .remoteUnsupported:
            return String(
                localized: "dialog.claudeAccountSwitch.remoteUnsupported.message",
                defaultValue: "Claude accounts can't be switched in a terminal that runs on another machine."
            )
        case .alreadySwitching:
            return String(
                localized: "dialog.claudeAccountSwitch.alreadySwitching.message",
                defaultValue: "This terminal is already switching Claude accounts."
            )
        case .transcriptUnavailable(let accountName):
            return String(
                format: String(
                    localized: "dialog.claudeAccountSwitch.transcriptUnavailable.message",
                    defaultValue: "cmux couldn't copy the conversation to the %@ account, so the terminal was left unchanged."
                ),
                accountName
            )
        case .respawnFailed:
            return String(
                localized: "dialog.claudeAccountSwitch.respawnFailed.message",
                defaultValue: "cmux couldn't restart the terminal, so it was left unchanged."
            )
        }
    }
}
