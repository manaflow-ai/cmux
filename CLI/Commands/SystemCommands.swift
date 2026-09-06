import ArgumentParser
import Foundation

struct OpenCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("pane"), completion: paneCompletion) var paneID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "open", helpNames: [])
}

struct DiffCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("source"), completion: .list(["unstaged", "staged", "branch", "last-turn"])) var source: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Option(name: .customLong("cwd"), completion: .directory) var cwd: String?
    @Option(name: .customLong("base")) var base: String?
    @Option(name: .customLong("title")) var title: String?
    @Option(name: .customLong("layout"), completion: .list(["split", "unified"])) var layout: String?
    @Option(name: .customLong("font-size")) var fontSize: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "diff", helpNames: [])
}

struct MarkdownCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("focus")) var focus: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "markdown", helpNames: [])
}

struct MemoryCommand: SharedLegacyFacadeCommand {
    @Flag(name: .customLong("all")) var all = false
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("groups")) var groups: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "memory", helpNames: [])
}

struct TopCommand: SharedLegacyFacadeCommand {
    @Flag(name: .customLong("all")) var all = false
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Flag(name: .customLong("processes")) var processes = false
    @Option(name: .customLong("sort"), completion: .list(["cpu", "mem", "proc"])) var sort: String?
    @Flag(name: .customLong("flat")) var flat = false
    @Option(name: .customLong("format"), completion: .list(["tree", "tsv"])) var format: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "top", helpNames: [])
}

struct TreeCommand: SharedLegacyFacadeCommand {
    @Flag(name: .customLong("all")) var all = false
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "tree", helpNames: [])
}

struct IdentifyCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Flag(name: .customLong("no-caller")) var noCaller = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "identify", helpNames: [])
}

struct TriggerFlashCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "trigger-flash", helpNames: [])
}

struct RestoreCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []

    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: String(
            localized: "cli.help.restore",
            defaultValue: "restore [--surface <id|ref>] <kind> <checkpoint-id> | restore --surface [id|ref]"
        ),
        helpNames: []
    )
}

/// Shares `restore`'s legacy dispatch arm and selector shape; the verb picks
/// between resuming the saved session and forking it.
struct ForkCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []

    static let configuration = CommandConfiguration(
        commandName: "fork",
        abstract: String(
            localized: "cli.help.fork",
            defaultValue: "fork [--surface <id|ref>] <kind> <checkpoint-id> | fork --surface [id|ref]"
        ),
        helpNames: []
    )
}

struct RestoreSessionCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "restore-session", helpNames: [])
}

struct RPCCommand: SharedLegacyFacadeCommand {
    @Argument var method: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "rpc", helpNames: [])
}

struct SimulatorCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []

    static let configuration = CommandConfiguration(
        commandName: "simulator",
        abstract: String(
            localized: "cli.help.simulator",
            defaultValue: "simulator <subcommand> [args] [--surface <id|ref|index>]"
        ),
        helpNames: []
    )
}

struct IOSCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []

    static let configuration = CommandConfiguration(
        commandName: "ios",
        abstract: String(
            localized: "cli.help.ios",
            defaultValue: "ios <subcommand> [args] [--surface <id|ref|index>]"
        ),
        helpNames: []
    )
}

struct MobileCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "mobile", helpNames: [])
}

struct SSHCommand: SharedLegacyFacadeCommand {
    @Argument var destination: String?
    @Option(name: .customLong("transport"), completion: .list(["ssh", "mosh"])) var transport: String?
    @Option(name: .customLong("name")) var name: String?
    @Option(name: .customLong("command")) var command: String?
    @Option(name: .customLong("port")) var port: String?
    @Option(name: .customLong("identity"), completion: .file()) var identity: String?
    @Flag(name: [.customShort("A"), .customLong("forward-agent")]) var forwardAgent = false
    @Flag(name: [.customShort("a"), .customLong("no-forward-agent")]) var noForwardAgent = false
    @Option(name: .customLong("ssh-option")) var sshOption: [String] = []
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Flag(name: .customLong("no-focus")) var noFocus = false
    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "ssh", helpNames: [])
}

struct MoshCommand: SharedLegacyFacadeCommand {
    @Argument var destination: String?
    @Option(name: .customLong("name")) var name: String?
    @Option(name: .customLong("command")) var command: String?
    @Option(name: .customLong("port")) var port: String?
    @Option(name: .customLong("identity"), completion: .file()) var identity: String?
    @Flag(name: [.customShort("A"), .customLong("forward-agent")]) var forwardAgent = false
    @Flag(name: [.customShort("a"), .customLong("no-forward-agent")]) var noForwardAgent = false
    @Option(name: .customLong("ssh-option")) var sshOption: [String] = []
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Flag(name: .customLong("no-focus")) var noFocus = false
    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "mosh", helpNames: [])
}

struct MoshTmuxCommand: SharedLegacyFacadeCommand {
    @Argument var destination: String?
    @Option(name: .customLong("session")) var session: String?
    @Option(name: .customLong("name")) var name: String?
    @Option(name: .customLong("command")) var command: String?
    @Option(name: .customLong("port")) var port: String?
    @Option(name: .customLong("identity"), completion: .file()) var identity: String?
    @Flag(name: [.customShort("A"), .customLong("forward-agent")]) var forwardAgent = false
    @Flag(name: [.customShort("a"), .customLong("no-forward-agent")]) var noForwardAgent = false
    @Option(name: .customLong("ssh-option")) var sshOption: [String] = []
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Flag(name: .customLong("no-focus")) var noFocus = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "mosh-tmux", helpNames: [])
}

struct SSHTmuxCommand: SharedLegacyFacadeCommand {
    @Argument var destination: String?
    @Option(name: .customLong("port")) var port: String?
    @Option(name: .customLong("identity"), completion: .file()) var identity: String?
    @Flag(name: .customLong("no-focus")) var noFocus = false
    @Flag(name: .customLong("new-window")) var newWindow = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "ssh-tmux", helpNames: [])
}

struct SSHSessionListCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Flag(name: .customLong("all-workspaces")) var allWorkspaces = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "ssh-session-list", helpNames: [])
}

struct SSHSessionAttachCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("session-id")) var sessionID: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("pane"), completion: paneCompletion) var paneID: String?
    @Option(name: .customLong("split"), completion: .list(["left", "right", "up", "down"])) var split: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "ssh-session-attach", helpNames: [])
}

struct SSHSessionCleanupCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Flag(name: .customLong("all-workspaces")) var allWorkspaces = false
    @Option(name: .customLong("session-id")) var sessionID: String?
    @Flag(name: .customLong("all")) var all = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "ssh-session-cleanup", helpNames: [])
}

/// Internal plumbing entry point, not part of the documented usage() surface.
struct SSHSessionEndCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "ssh-session-end", shouldDisplay: false, helpNames: [])
}

/// Internal plumbing entry point, not part of the documented usage() surface.
struct SSHPTYAttachCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "ssh-pty-attach", shouldDisplay: false, helpNames: [])
}

/// Internal plumbing entry point, not part of the documented usage() surface.
struct VMPtyAttachCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("id"), completion: vmCompletion) var id: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "vm-pty-attach", shouldDisplay: false, helpNames: [])
}

/// Internal plumbing entry point, not part of the documented usage() surface.
struct VMPtyConnectCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("id"), completion: vmCompletion) var id: String?
    @Option(name: .customLong("config"), completion: .file()) var config: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "vm-pty-connect", shouldDisplay: false, helpNames: [])
}

/// Internal plumbing entry point, not part of the documented usage() surface.
/// Runs inside the pane that `cmux vm tui` opens.
struct VMTuiConnectCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("config"), completion: .file()) var config: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "vm-tui-connect", shouldDisplay: false, helpNames: [])
}

/// Internal plumbing entry point, not part of the documented usage() surface.
/// Spawned detached by `vm-tui-connect` to approve the enrollment invitation.
struct VMTuiApproveCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("id"), completion: vmCompletion) var id: String?
    @Option(name: .customLong("invitation-id")) var invitationID: String?
    @Option(name: .customLong("invite-file"), completion: .file()) var inviteFile: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "vm-tui-approve", shouldDisplay: false, helpNames: [])
}

/// Hidden compatibility alias for workspaces created before the split helper was nested under `cmux vm`.
struct VMSSHAttachTopLevelCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("id"), completion: vmCompletion) var id: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "vm-ssh-attach", shouldDisplay: false, helpNames: [])
}

struct TodoCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "todo", helpNames: [])
}

struct CommentsCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("repo"), completion: .directory) var repo: String?
    @Flag(name: .customLong("all")) var all = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "comments", helpNames: [])
}

struct SidebarCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "sidebar", helpNames: [])
}

struct RightSidebarCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Flag(name: .customLong("no-focus")) var noFocus = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "right-sidebar", helpNames: [])
}

struct SetAppFocusCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "set-app-focus", helpNames: [])
}

struct SimulateAppActiveCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "simulate-app-active", helpNames: [])
}

struct SimulateSidebarDragCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Option(name: .customLong("from")) var from: String?
    @Option(name: .customLong("to")) var to: String?
    @Option(name: .customLong("duration-ms")) var durationMS: String?
    @Option(name: .customLong("steps")) var steps: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "simulate-sidebar-drag", helpNames: [])
}

struct ProjectCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "project", helpNames: [])
}

struct WindowNamespaceCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "window", helpNames: [])
}

struct CanvasCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "canvas", helpNames: [])
}

struct LayoutCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "layout", helpNames: [])
}

struct AutomationCommand: SharedLegacyFacadeCommand {
    // See AuthCommand's comment: no catch-all argument alongside `subcommands`.
    static let configuration = CommandConfiguration(
        commandName: "automation",
        subcommands: [
            AutomationListCommand.self,
            AutomationShowCommand.self,
            AutomationTestCommand.self,
            AutomationEnableCommand.self,
            AutomationDisableCommand.self,
            AutomationLogsCommand.self,
            AutomationReloadCommand.self,
        ],
        defaultSubcommand: AutomationListCommand.self,
        helpNames: []
    )
}

struct AutomationListCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list", helpNames: [])
}

struct AutomationShowCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "show", helpNames: [])
}

struct AutomationTestCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("event")) var event: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "test", helpNames: [])
}

struct AutomationEnableCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "enable", helpNames: [])
}

struct AutomationDisableCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "disable", helpNames: [])
}

struct AutomationLogsCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("limit")) var limit: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "logs", helpNames: [])
}

struct AutomationReloadCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "reload", helpNames: [])
}

struct VPNCommand: SharedLegacyFacadeCommand {
    // See AuthCommand's comment: no catch-all argument alongside `subcommands`.
    static let configuration = CommandConfiguration(
        commandName: "vpn",
        subcommands: [
            VPNUpCommand.self,
            VPNDownCommand.self,
            VPNStatusCommand.self,
            VPNRevokeCommand.self,
        ],
        defaultSubcommand: VPNStatusCommand.self,
        helpNames: []
    )
}

struct VPNUpCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "up", helpNames: [], aliases: ["on"])
}

struct VPNDownCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "down", helpNames: [], aliases: ["off"])
}

struct VPNStatusCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "status", helpNames: [])
}

struct VPNRevokeCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "revoke", helpNames: [])
}

struct VaultCommand: SharedLegacyFacadeCommand {
    // See AuthCommand's comment: no catch-all argument alongside `subcommands`.
    static let configuration = CommandConfiguration(
        commandName: "vault",
        subcommands: [
            VaultSessionsCommand.self,
            VaultSearchCommand.self,
            VaultCheckpointsCommand.self,
            VaultCheckpointCommand.self,
            VaultForkCommand.self,
        ],
        defaultSubcommand: VaultSessionsCommand.self,
        helpNames: []
    )
}

struct VaultSessionsCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("agent")) var agent: String?
    @Option(name: .customLong("folder"), completion: .directory) var folder: String?
    @Option(name: .customLong("limit")) var limit: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "sessions", helpNames: [], aliases: ["ls"])
}

struct VaultSearchCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("limit")) var limit: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "search", helpNames: [])
}

struct VaultCheckpointsCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("agent")) var agent: String?
    @Option(name: .customLong("session")) var session: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "checkpoints", helpNames: [])
}

struct VaultCheckpointCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("agent")) var agent: String?
    @Option(name: .customLong("session")) var session: String?
    @Option(name: .customLong("name")) var name: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "checkpoint", helpNames: [])
}

struct VaultForkCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("agent")) var agent: String?
    @Option(name: .customLong("session")) var session: String?
    @Option(name: .customLong("checkpoint")) var checkpoint: String?
    @Option(name: .customLong("turn")) var turn: String?
    @Flag(name: .customLong("open")) var open = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "fork", helpNames: [])
}
