import Foundation

/// The Chief's tool rows and approval cards (Resources/CmuxHome.xcstrings, every app language).
extension CmuxStrings {
    /// A command still running: "Running cmux tree --all".
    static func toolRunning(_ command: String) -> String {
        String(localized: "home.tool.running", defaultValue: "Running \(command)", table: "CmuxHome", bundle: .module)
    }
    /// Tool titles the owner stores in English ("Read <path>"), in the user's language.
    static func toolRead(_ path: String) -> String {
        String(localized: "home.tool.read", defaultValue: "Read \(path)", table: "CmuxHome", bundle: .module)
    }
    static func toolWrite(_ path: String) -> String {
        String(localized: "home.tool.write", defaultValue: "Write \(path)", table: "CmuxHome", bundle: .module)
    }
    static func toolEdit(_ path: String) -> String {
        String(localized: "home.tool.edit", defaultValue: "Edit \(path)", table: "CmuxHome", bundle: .module)
    }
    static func toolSearch(_ pattern: String) -> String {
        String(localized: "home.tool.search", defaultValue: "Search \(pattern)", table: "CmuxHome", bundle: .module)
    }
    static func toolSearchWeb(_ query: String) -> String {
        String(localized: "home.tool.searchWeb", defaultValue: "Search the web: \(query)", table: "CmuxHome", bundle: .module)
    }
    static func toolFetch(_ url: String) -> String {
        String(localized: "home.tool.fetch", defaultValue: "Fetch \(url)", table: "CmuxHome", bundle: .module)
    }
    static var toolFindTools: String {
        String(localized: "home.tool.findTools", defaultValue: "Find tools", table: "CmuxHome", bundle: .module)
    }
    /// A finished command: "Ran cmux tree --all".
    static func toolRan(_ command: String) -> String {
        String(localized: "home.tool.ran", defaultValue: "Ran \(command)", table: "CmuxHome", bundle: .module)
    }
    /// A command that failed: "Failed cmux tree --all".
    static func toolFailed(_ command: String) -> String {
        String(localized: "home.tool.failed", defaultValue: "Failed \(command)", table: "CmuxHome", bundle: .module)
    }
    /// `cmux chief dispatch`'s subject: "Codex in “#12: fix login”" (the agent and its workspace).
    static func dispatchSubject(agent: String, workspace: String) -> String {
        String(localized: "home.tool.dispatch.subject", defaultValue: "\(agent) in “\(workspace)”", table: "CmuxHome", bundle: .module)
    }
    /// `cmux chief dispatch` while it runs, done and failed (the subject above, or the agent alone).
    static func dispatchStarting(_ subject: String) -> String {
        String(localized: "home.tool.dispatch.starting", defaultValue: "Starting \(subject)", table: "CmuxHome", bundle: .module)
    }
    /// `cmux chief dispatch` asked for in an approval card, in the list's preview: "Start Codex in “Scratch”".
    static func dispatchStart(_ subject: String) -> String {
        String(localized: "home.tool.dispatch.start", defaultValue: "Start \(subject)", table: "CmuxHome", bundle: .module)
    }
    /// A conversation's list preview while an approval card waits: "Needs your approval: Start Codex in “Scratch”".
    static func previewNeedsApproval(_ subject: String) -> String {
        String(localized: "home.preview.needsApproval", defaultValue: "Needs your approval: \(subject)", table: "CmuxHome", bundle: .module)
    }
    /// A conversation's list preview while a question card waits: "Needs your answer: Which machine size?".
    static func previewNeedsAnswer(_ question: String) -> String {
        String(localized: "home.preview.needsAnswer", defaultValue: "Needs your answer: \(question)", table: "CmuxHome", bundle: .module)
    }
    static func dispatchStarted(_ subject: String) -> String {
        String(localized: "home.tool.dispatch.started", defaultValue: "Started \(subject)", table: "CmuxHome", bundle: .module)
    }
    static func dispatchFailed(_ subject: String) -> String {
        String(localized: "home.tool.dispatch.failed", defaultValue: "Couldn’t start \(subject)", table: "CmuxHome", bundle: .module)
    }
    /// A run of shell commands (2 or more).
    static func ranCommands(_ count: Int) -> String {
        String(localized: "home.tool.ranCommands", defaultValue: "Ran \(count) commands", table: "CmuxHome", bundle: .module)
    }
    /// A collapsed run with failures: "1 of 4 failed: cmux tree --all" (the first failed call).
    static func toolsFailedOf(_ failed: Int, total: Int, _ subject: String) -> String {
        String(localized: "home.tool.failedOf", defaultValue: "\(failed) of \(total) failed: \(subject)", table: "CmuxHome", bundle: .module)
    }
    /// A run of tool calls of several kinds (2 or more).
    static func usedTools(_ count: Int) -> String {
        String(localized: "home.tool.usedTools", defaultValue: "Used \(count) tools", table: "CmuxHome", bundle: .module)
    }
    static var toolStateRunning: String {
        String(localized: "home.tool.state.running", defaultValue: "Running", table: "CmuxHome", bundle: .module)
    }
    static var toolStateDone: String {
        String(localized: "home.tool.state.done", defaultValue: "Done", table: "CmuxHome", bundle: .module)
    }
    static var toolStateFailed: String {
        String(localized: "home.tool.state.failed", defaultValue: "Failed", table: "CmuxHome", bundle: .module)
    }
    /// The run row's tooltip and accessibility hint while collapsed / expanded.
    static var toolShowAll: String {
        String(localized: "home.tool.showAll", defaultValue: "Show All", table: "CmuxHome", bundle: .module)
    }
    static var toolHide: String {
        String(localized: "home.tool.hide", defaultValue: "Hide", table: "CmuxHome", bundle: .module)
    }

    static var approvalAllow: String {
        String(localized: "home.approval.allow", defaultValue: "Allow", table: "CmuxHome", bundle: .module)
    }
    static var approvalDeny: String {
        String(localized: "home.approval.deny", defaultValue: "Deny", table: "CmuxHome", bundle: .module)
    }
    static var approvalAllowed: String {
        String(localized: "home.approval.allowed", defaultValue: "Allowed", table: "CmuxHome", bundle: .module)
    }
    static var approvalDenied: String {
        String(localized: "home.approval.denied", defaultValue: "Denied", table: "CmuxHome", bundle: .module)
    }
    /// The decided state of a card whose turn ended with an earlier run of the app
    /// (the owner's `ChiefConversationOwner.approvalExpired`).
    static var approvalExpired: String {
        String(localized: "home.approval.expired", defaultValue: "Expired", table: "CmuxHome", bundle: .module)
    }
    /// A command approval's prompt (the owner stores "Run `<command>`?").
    static func approvalRunPrompt(_ command: String) -> String {
        String(localized: "home.approval.prompt.run", defaultValue: "Run `\(command)`?", table: "CmuxHome", bundle: .module)
    }
    /// Another tool's approval prompt (the owner stores "Allow <tool title>?").
    static func approvalAllowPrompt(_ title: String) -> String {
        String(localized: "home.approval.prompt.allow", defaultValue: "Allow \(title)?", table: "CmuxHome", bundle: .module)
    }
    /// The decided state for an option other than Allow or Deny.
    static func approvalChose(_ option: String) -> String {
        String(localized: "home.approval.chose", defaultValue: "Chose “\(option)”", table: "CmuxHome", bundle: .module)
    }
    /// The decided receipt for a command: "Allowed: cmux tree".
    static func approvalAllowedCommand(_ command: String) -> String {
        String(localized: "home.approval.allowedCommand", defaultValue: "Allowed: \(command)", table: "CmuxHome", bundle: .module)
    }
    /// The pending card's reason line under its command.
    static var approvalReasonDispatch: String {
        String(localized: "home.approval.reason.dispatch", defaultValue: "Starts a coding agent", table: "CmuxHome", bundle: .module)
    }
    static var approvalReasonCloud: String {
        String(localized: "home.approval.reason.cloud", defaultValue: "Creates a cloud machine", table: "CmuxHome", bundle: .module)
    }
    /// The words no allow rule covers yet ("cmux close-workspace").
    static func approvalReasonNotAllowed(_ words: String) -> String {
        String(localized: "home.approval.reason.notAllowed", defaultValue: "Not in your allowed commands: \(words)",
               table: "CmuxHome", bundle: .module)
    }
    /// The pending card's caption over its command.
    static func approvalWantsToRun(_ agent: String) -> String {
        String(localized: "home.approval.wantsToRun", defaultValue: "\(agent) wants to run", table: "CmuxHome", bundle: .module)
    }
    /// The pending card's caption over another request.
    static func approvalAsks(_ agent: String) -> String {
        String(localized: "home.approval.asks", defaultValue: "\(agent) is asking", table: "CmuxHome", bundle: .module)
    }
    /// The chevron menu's item: allow this program and subcommand from now on.
    static func approvalAlwaysAllow(_ prefix: String) -> String {
        String(localized: "home.approval.alwaysAllow", defaultValue: "Always Allow “\(prefix) …”", table: "CmuxHome", bundle: .module)
    }
    /// The chevron button's accessibility label.
    static var approvalMoreOptions: String {
        String(localized: "home.approval.moreOptions", defaultValue: "More Options", table: "CmuxHome", bundle: .module)
    }
    /// The buttons' accessibility labels over a command.
    static func approvalAllowRunning(_ command: String) -> String {
        String(localized: "home.approval.allowRunning", defaultValue: "Allow running \(command)", table: "CmuxHome", bundle: .module)
    }
    static func approvalDenyRunning(_ command: String) -> String {
        String(localized: "home.approval.denyRunning", defaultValue: "Deny running \(command)", table: "CmuxHome", bundle: .module)
    }
    /// The field's placeholder while an approval waits.
    static var approvalPlaceholder: String {
        String(localized: "home.approval.placeholder", defaultValue: "Allow or deny above to continue", table: "CmuxHome", bundle: .module)
    }
    /// The header's status while an approval waits.
    static var waitingForYou: String {
        String(localized: "home.status.waitingForYou", defaultValue: "Waiting for you", table: "CmuxHome", bundle: .module)
    }
    /// The prominent button's tooltip (its key).
    static var approvalProminentHelp: String {
        String(localized: "home.approval.prominentHelp", defaultValue: "Return", table: "CmuxHome", bundle: .module)
    }
    /// The refusing button's tooltip (its key).
    static var approvalRefusalHelp: String {
        String(localized: "home.approval.refusalHelp", defaultValue: "Esc", table: "CmuxHome", bundle: .module)
    }
    /// The card's accessibility role description.
    static var approvalRole: String {
        String(localized: "home.approval.role", defaultValue: "approval request", table: "CmuxHome", bundle: .module)
    }

    /// A failed turn's row: its button resends the last message, and its accessibility role.
    static var failureTryAgain: String {
        String(localized: "home.failure.tryAgain", defaultValue: "Try Again", table: "CmuxHome", bundle: .module)
    }
    static var failureTryAgainHelp: String {
        String(localized: "home.failure.tryAgainHelp", defaultValue: "Send your last message again", table: "CmuxHome", bundle: .module)
    }
    static var failureRole: String {
        String(localized: "home.failure.role", defaultValue: "error", table: "CmuxHome", bundle: .module)
    }
    /// A saved memory note's row, saved during a turn or outside one (one wording for both), and after Undo.
    static func memoryWillRemember(_ note: String) -> String {
        String(localized: "home.memory.willRemember", defaultValue: "Chief will remember: \(note)", table: "CmuxHome", bundle: .module)
    }
    static func memoryForgotten(_ note: String) -> String {
        String(localized: "home.memory.forgotten", defaultValue: "Removed from memory: \(note)", table: "CmuxHome", bundle: .module)
    }
    static var memoryUndo: String {
        String(localized: "home.memory.undo", defaultValue: "Undo", table: "CmuxHome", bundle: .module)
    }
    static var memoryUndoHelp: String {
        String(localized: "home.memory.undoHelp", defaultValue: "Forget this note", table: "CmuxHome", bundle: .module)
    }
}
