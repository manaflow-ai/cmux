import Foundation

/// The Chief's tool rows and approval cards (Resources/CmuxHome.xcstrings, every app language).
extension CmuxStrings {
    /// A command still running: "Running cmux tree --all".
    static func toolRunning(_ command: String) -> String {
        String(localized: "home.tool.running", defaultValue: "Running \(command)", table: "CmuxHome", bundle: .module)
    }
    /// A finished command: "Ran cmux tree --all".
    static func toolRan(_ command: String) -> String {
        String(localized: "home.tool.ran", defaultValue: "Ran \(command)", table: "CmuxHome", bundle: .module)
    }
    /// A run of shell commands (2 or more).
    static func ranCommands(_ count: Int) -> String {
        String(localized: "home.tool.ranCommands", defaultValue: "Ran \(count) commands", table: "CmuxHome", bundle: .module)
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
    /// The decided state for an option other than Allow or Deny.
    static func approvalChose(_ option: String) -> String {
        String(localized: "home.approval.chose", defaultValue: "Chose “\(option)”", table: "CmuxHome", bundle: .module)
    }
    /// The decided receipt for a command: "Allowed: cmux tree".
    static func approvalAllowedCommand(_ command: String) -> String {
        String(localized: "home.approval.allowedCommand", defaultValue: "Allowed: \(command)", table: "CmuxHome", bundle: .module)
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
}
