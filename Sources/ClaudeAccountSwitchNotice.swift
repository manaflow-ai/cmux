import CMUXAgentLaunch
import Foundation

/// What the user is told after a Claude account switch that did not end with the conversation
/// resumed on the new account. One case per way a switch can fall short.
enum ClaudeAccountSwitchNotice: Equatable, Sendable {
    /// The pane now runs on `accountName`, but cmux never typed the resume `command`, so the
    /// user runs it. `paneClosed` means the respawned terminal is gone (closed, moved to another
    /// workspace or restarted again), so there is nothing to type it into.
    case resumeManually(accountName: String, command: String, paneClosed: Bool)
    /// The pane now runs on `accountName`, but the replaced Claude (`processIDs`) was still
    /// running, so cmux did not resume: the user runs `command` once it has quit.
    case previousClaudeStillRunning(accountName: String, command: String, processIDs: [Int32])
    /// The pane now runs on `accountName`, but copying the transcript there again after the
    /// replaced Claude quit failed, so the copy may miss its last messages. cmux did not resume;
    /// the user runs `command` to continue from that copy anyway.
    case transcriptResyncFailed(accountName: String, command: String)
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
    /// The session's Claude runs inside tmux or screen, in another terminal, or detached, so
    /// restarting the pane would not stop it; the pane was left alone.
    case agentNotOwnedByPane
    /// A switch for the pane is already in progress.
    case alreadySwitching
    /// Claude started responding while the switch prepared, before anyone agreed to stop it; the
    /// pane was left alone.
    case agentRunning
    /// The transcript could not be made available to `accountName`; the pane was left alone.
    case transcriptUnavailable(accountName: String)
    /// The terminal could not be restarted; the pane was left alone.
    case respawnFailed

    /// The notice for `result`, or `nil` when the conversation resumed on the new account.
    ///
    /// - Parameters:
    ///   - result: What ``Workspace/switchClaudeAccount(panelId:toAccountNamed:trigger:stopsRunningResponse:)`` returned.
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
            case .transcriptResyncFailed:
                self = .transcriptResyncFailed(accountName: plan.target.name, command: manualResume.command)
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
        case .agentRunning:
            self = .agentRunning
        case .transcriptUnavailable:
            self = .transcriptUnavailable(accountName: requestedAccountName)
        case .respawnFailed:
            self = .respawnFailed
        }
    }

    /// Whether the switch failed and the pane was left as it was.
    var reportsFailure: Bool {
        switch self {
        case .resumeManually, .previousClaudeStillRunning, .transcriptResyncFailed:
            return false
        default:
            return true
        }
    }

    /// Whether the alert can offer to type the resume command into the respawned pane.
    var offersTypingResumeCommand: Bool {
        switch self {
        case .resumeManually(_, _, paneClosed: false), .transcriptResyncFailed:
            return true
        default:
            return false
        }
    }

    /// The alert's headline.
    var title: String {
        switch self {
        case .resumeManually(let accountName, _, _), .previousClaudeStillRunning(let accountName, _, _),
             .transcriptResyncFailed(let accountName, _):
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
        switch self {
        case .resumeManually(_, let command, paneClosed: false):
            return String(
                format: String(
                    localized: "notification.claudeAccountSwitch.resumeManually.message",
                    defaultValue: "cmux couldn't resume the conversation automatically. To continue it, run this command in the terminal:\n\n%@"
                ),
                command
            )
        default:
            return message
        }
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
                    defaultValue: "The terminal was closed, moved or restarted before cmux could resume the conversation. To continue it, run this command in a terminal:\n\n%@"
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
        case .transcriptResyncFailed(_, let command):
            // Names no button: the alert drops Type Resume Command when the pane closed while the
            // switch waited for the old Claude to exit.
            return String(
                format: String(
                    localized: "dialog.claudeAccountSwitch.transcriptResyncFailed.message",
                    defaultValue: "cmux couldn't copy the conversation's latest messages to this account, so it didn't resume the conversation: the copy here may be missing them. To continue from this copy anyway, run this command in the terminal:\n\n%@"
                ),
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
                defaultValue: "The Claude that runs this conversation is inside tmux or screen, in another terminal, or detached from any terminal, so restarting this terminal wouldn't stop it and the conversation would run in two places. The terminal was left unchanged."
            )
        case .alreadySwitching:
            return String(
                localized: "dialog.claudeAccountSwitch.alreadySwitching.message",
                defaultValue: "This terminal is already switching Claude accounts."
            )
        case .agentRunning:
            return String(
                localized: "dialog.claudeAccountSwitch.agentRunning.message",
                defaultValue: "Claude started responding in this terminal while cmux prepared the switch, so the terminal was left unchanged. Choose the account again to stop the response and switch."
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
