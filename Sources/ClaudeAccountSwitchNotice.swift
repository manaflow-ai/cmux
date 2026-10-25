import CMUXAgentLaunch
import Foundation

/// What the user is told after a Claude account switch that did not end with the conversation
/// resumed on the new account. One case per way a switch can fall short.
enum ClaudeAccountSwitchNotice: Equatable, Sendable {
    /// The pane now runs on `accountName`, but cmux never typed the resume `command`, so the
    /// user runs it. `paneClosed` means the respawned pane is gone, so there is nothing to type
    /// it into.
    case resumeManually(accountName: String, command: String, paneClosed: Bool)
    /// The pane now runs on `accountName`, but the replaced Claude (`processIDs`) was still
    /// running, so cmux did not resume: the user runs `command` once it has quit.
    case previousClaudeStillRunning(accountName: String, command: String, processIDs: [Int32])
    /// No registered account has this name.
    case unknownAccount(String)
    /// The pane already runs on this account.
    case alreadyOnAccount(String)
    /// cmux could not confirm or resume the pane's Claude conversation.
    case noClaudeSession
    /// The conversation's working directory is unknown.
    case missingWorkingDirectory
    /// cmux found no message in the conversation to continue: usually none has been sent yet,
    /// but a transcript missing from the account directory cmux looked in reads the same.
    case noConversationYet
    /// The conversation went on separately under both accounts; `newerAccount` has the copy
    /// written last. cmux does not merge them, so the pane was left alone.
    case transcriptDiverged(newerAccount: String)
    /// The pane is not running Claude.
    case notClaude
    /// The pane runs on another machine.
    case remoteUnsupported
    /// The pane's Claude runs inside tmux or screen, or detached, so restarting the pane would
    /// not stop it; the pane was left alone.
    case agentNotOwnedByPane
    /// A switch for the pane is already in progress.
    case alreadySwitching
    /// The transcript could not be made available to `accountName`; the pane was left alone.
    case transcriptUnavailable(accountName: String)
    /// The terminal could not be restarted; the pane was left alone.
    case respawnFailed
    /// An automatic switch found the terminal in use right before restarting it; the pane was
    /// left alone.
    case paneInUse

    /// The notice for `result`, or `nil` when the conversation resumed on the new account.
    ///
    /// - Parameters:
    ///   - result: What ``Workspace/switchClaudeAccount(panelId:toAccountNamed:trigger:)`` returned.
    ///   - requestedAccountName: The account the user picked, named by results that carry no plan.
    init?(result: ClaudeAccountSwitchResult, requestedAccountName: String) {
        switch result {
        case .switched:
            return nil
        case .switchedWithoutResume(let plan, _, let manualResume):
            switch manualResume.reason {
            case .paneReplaced, .notTyped:
                self = .resumeManually(
                    accountName: plan.target.name,
                    command: manualResume.command,
                    paneClosed: manualResume.paneWasReplaced
                )
            case .previousClaudeStillRunning(let processIDs):
                self = .previousClaudeStillRunning(
                    accountName: plan.target.name,
                    command: manualResume.command,
                    processIDs: processIDs
                )
            }
        case .refused(.noClaudeSession):
            self = .noClaudeSession
        case .refused(.missingWorkingDirectory):
            self = .missingWorkingDirectory
        case .refused(.noConversationYet):
            self = .noConversationYet
        case .refused(.transcriptDiverged(let newerAccount)):
            self = .transcriptDiverged(newerAccount: newerAccount)
        case .refused(.unknownAccount(let name)):
            self = .unknownAccount(name)
        case .refused(.sameAccount(let name)):
            self = .alreadyOnAccount(name)
        case .notClaude:
            self = .notClaude
        case .remoteUnsupported:
            self = .remoteUnsupported
        case .agentNotOwnedByPane:
            self = .agentNotOwnedByPane
        case .alreadySwitching:
            self = .alreadySwitching
        case .transcriptUnavailable:
            self = .transcriptUnavailable(accountName: requestedAccountName)
        case .respawnFailed:
            self = .respawnFailed
        case .paneInUse:
            self = .paneInUse
        }
    }

    /// Whether the switch failed and the pane was left as it was.
    var reportsFailure: Bool {
        switch self {
        case .resumeManually, .previousClaudeStillRunning:
            return false
        default:
            return true
        }
    }

    /// Whether the alert can offer to type the resume command into the respawned pane.
    var offersTypingResumeCommand: Bool {
        if case .resumeManually(_, _, paneClosed: false) = self { return true }
        return false
    }

    /// The alert's headline.
    var title: String {
        switch self {
        case .resumeManually(let accountName, _, _), .previousClaudeStillRunning(let accountName, _, _):
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

    /// The explanation for a cmux notification. It matches ``message`` except where the alert
    /// points at its Type Resume Command button, which a notification does not have.
    var notificationMessage: String {
        guard case .resumeManually(_, let command, paneClosed: false) = self else { return message }
        return String(
            format: String(
                localized: "notification.claudeAccountSwitch.resumeManually.message",
                defaultValue: "cmux couldn't resume the conversation automatically. To continue it, run this command in the terminal:\n\n%@"
            ),
            command
        )
    }

    /// The alert's explanation.
    var message: String {
        switch self {
        case .resumeManually(_, let command, paneClosed: false):
            // The command is shown verbatim: it unsets the account keys the shell may re-export.
            return String(
                format: String(
                    localized: "dialog.claudeAccountSwitch.resumeManually.message",
                    defaultValue: "cmux couldn't resume the conversation automatically. To continue it in this terminal, choose Type Resume Command, or run:\n\n%@"
                ),
                command
            )
        case .resumeManually(_, let command, paneClosed: true):
            return String(
                format: String(
                    localized: "dialog.claudeAccountSwitch.resumeManuallyPaneClosed.message",
                    defaultValue: "The terminal was closed before cmux could resume the conversation. To continue it, run this command in a terminal:\n\n%@"
                ),
                command
            )
        case .previousClaudeStillRunning(_, let command, let processIDs):
            return String(
                format: String(
                    localized: "dialog.claudeAccountSwitch.previousClaudeStillRunning.message",
                    defaultValue: "The previous Claude (process %1$@) is still running, so cmux didn't resume the conversation here: it would run in two places. Once that Claude has quit, run this command in this terminal:\n\n%2$@"
                ),
                processIDs.map(String.init).joined(separator: ", "),
                command
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
        case .noConversationYet:
            return String(
                localized: "dialog.claudeAccountSwitch.noConversationYet.message",
                defaultValue: "cmux couldn't find any messages in this conversation to continue on another account. If you haven't sent one yet, send a message, then switch."
            )
        case .transcriptDiverged(let newerAccount):
            return String(
                format: String(
                    localized: "dialog.claudeAccountSwitch.transcriptDiverged.message",
                    defaultValue: "This conversation was continued separately on both accounts, and the newer copy is on %@. cmux can't merge the two copies, so the terminal was left unchanged."
                ),
                newerAccount
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
        case .agentNotOwnedByPane:
            return String(
                localized: "dialog.claudeAccountSwitch.agentNotOwnedByPane.message",
                defaultValue: "Claude in this terminal runs inside tmux or screen, or detached from the terminal, so restarting the terminal wouldn't stop it and the conversation would run in two places. The terminal was left unchanged."
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
        case .paneInUse:
            return String(
                localized: "dialog.claudeAccountSwitch.paneInUse.message",
                defaultValue: "The terminal was in use, so cmux left it unchanged instead of switching accounts."
            )
        }
    }
}
