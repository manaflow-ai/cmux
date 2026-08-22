import ArgumentParser
import Foundation

/// Routes remaining system facade declarations through the established CLI implementation.
private protocol LegacySystemCommand: ParsableCommand {}

extension LegacySystemCommand {
    func run() throws {
        try GlobalOptions().makeCLI().run()
    }
}

private protocol SystemTargetCommand: LegacySystemCommand {}

extension SystemTargetCommand {
    static var workspace: CompletionKind { .custom(CompletionCandidates.workspaces) }
    static var surface: CompletionKind { .custom(CompletionCandidates.surfaces) }
    static var window: CompletionKind { .custom(CompletionCandidates.windows) }
    static var pane: CompletionKind { .custom(CompletionCandidates.panes) }
    static var vmID: CompletionKind { .custom(CompletionCandidates.vms) }
}

struct OpenCommand: SystemTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("pane"), completion: pane) var paneID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "open", helpNames: [])
}

struct DiffCommand: SystemTargetCommand {
    @Option(name: .customLong("source"), completion: .list(["unstaged", "staged", "branch", "last-turn"])) var source: String?
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Option(name: .customLong("cwd"), completion: .directory) var cwd: String?
    @Option(name: .customLong("base")) var base: String?
    @Option(name: .customLong("title")) var title: String?
    @Option(name: .customLong("layout"), completion: .list(["split", "unified"])) var layout: String?
    @Option(name: .customLong("font-size")) var fontSize: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "diff", helpNames: [])
}

struct MarkdownCommand: LegacySystemCommand {
    @Option(name: .customLong("focus")) var focus: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "markdown", helpNames: [])
}

struct MemoryCommand: SystemTargetCommand {
    @Flag(name: .customLong("all")) var all = false
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("groups")) var groups: Int?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "memory", helpNames: [])
}

struct TopCommand: SystemTargetCommand {
    @Flag(name: .customLong("all")) var all = false
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Flag(name: .customLong("processes")) var processes = false
    @Option(name: .customLong("sort"), completion: .list(["cpu", "mem", "proc"])) var sort: String?
    @Flag(name: .customLong("flat")) var flat = false
    @Option(name: .customLong("format"), completion: .list(["tree", "tsv"])) var format: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "top", helpNames: [])
}

struct TreeCommand: SystemTargetCommand {
    @Flag(name: .customLong("all")) var all = false
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "tree", helpNames: [])
}

struct IdentifyCommand: SystemTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Flag(name: .customLong("no-caller")) var noCaller = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "identify", helpNames: [])
}

struct TriggerFlashCommand: SystemTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "trigger-flash", helpNames: [])
}

struct RestoreCommand: SystemTargetCommand {
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
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

struct RestoreSessionCommand: LegacySystemCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "restore-session", helpNames: [])
}

struct RPCCommand: LegacySystemCommand {
    @Argument var method: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "rpc", helpNames: [])
}

struct SimulatorCommand: SystemTargetCommand {
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
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

struct IOSCommand: SystemTargetCommand {
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
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

struct MobileCommand: SystemTargetCommand {
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "mobile", helpNames: [])
}

struct SSHCommand: SystemTargetCommand {
    @Argument var destination: String?
    @Option(name: .customLong("transport"), completion: .list(["ssh", "mosh"])) var transport: String?
    @Option(name: .customLong("name")) var name: String?
    @Option(name: .customLong("command")) var command: String?
    @Option(name: .customLong("port")) var port: Int?
    @Option(name: .customLong("identity"), completion: .file()) var identity: String?
    @Flag(name: [.customShort("A"), .customLong("forward-agent")]) var forwardAgent = false
    @Flag(name: [.customShort("a"), .customLong("no-forward-agent")]) var noForwardAgent = false
    @Option(name: .customLong("ssh-option")) var sshOption: [String] = []
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Flag(name: .customLong("no-focus")) var noFocus = false
    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "ssh", helpNames: [])
}

struct MoshCommand: SystemTargetCommand {
    @Argument var destination: String?
    @Option(name: .customLong("name")) var name: String?
    @Option(name: .customLong("command")) var command: String?
    @Option(name: .customLong("port")) var port: Int?
    @Option(name: .customLong("identity"), completion: .file()) var identity: String?
    @Flag(name: [.customShort("A"), .customLong("forward-agent")]) var forwardAgent = false
    @Flag(name: [.customShort("a"), .customLong("no-forward-agent")]) var noForwardAgent = false
    @Option(name: .customLong("ssh-option")) var sshOption: [String] = []
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Flag(name: .customLong("no-focus")) var noFocus = false
    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "mosh", helpNames: [])
}

struct MoshTmuxCommand: SystemTargetCommand {
    @Argument var destination: String?
    @Option(name: .customLong("session")) var session: String?
    @Option(name: .customLong("name")) var name: String?
    @Option(name: .customLong("command")) var command: String?
    @Option(name: .customLong("port")) var port: Int?
    @Option(name: .customLong("identity"), completion: .file()) var identity: String?
    @Flag(name: [.customShort("A"), .customLong("forward-agent")]) var forwardAgent = false
    @Flag(name: [.customShort("a"), .customLong("no-forward-agent")]) var noForwardAgent = false
    @Option(name: .customLong("ssh-option")) var sshOption: [String] = []
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Flag(name: .customLong("no-focus")) var noFocus = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "mosh-tmux", helpNames: [])
}

struct SSHTmuxCommand: LegacySystemCommand {
    @Argument var destination: String?
    @Option(name: .customLong("port")) var port: Int?
    @Option(name: .customLong("identity"), completion: .file()) var identity: String?
    @Flag(name: .customLong("no-focus")) var noFocus = false
    @Flag(name: .customLong("new-window")) var newWindow = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "ssh-tmux", helpNames: [])
}

struct SSHSessionListCommand: SystemTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Flag(name: .customLong("all-workspaces")) var allWorkspaces = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "ssh-session-list", helpNames: [])
}

struct SSHSessionAttachCommand: SystemTargetCommand {
    @Option(name: .customLong("session-id")) var sessionID: String?
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("pane"), completion: pane) var paneID: String?
    @Option(name: .customLong("split"), completion: .list(["left", "right", "up", "down"])) var split: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "ssh-session-attach", helpNames: [])
}

struct SSHSessionCleanupCommand: SystemTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Flag(name: .customLong("all-workspaces")) var allWorkspaces = false
    @Option(name: .customLong("session-id")) var sessionID: String?
    @Flag(name: .customLong("all")) var all = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "ssh-session-cleanup", helpNames: [])
}

/// Internal plumbing entry point, not part of the documented usage() surface.
struct SSHSessionEndCommand: LegacySystemCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "ssh-session-end", shouldDisplay: false, helpNames: [])
}

/// Internal plumbing entry point, not part of the documented usage() surface.
struct SSHPTYAttachCommand: LegacySystemCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "ssh-pty-attach", shouldDisplay: false, helpNames: [])
}

/// Internal plumbing entry point, not part of the documented usage() surface.
struct VMPtyAttachCommand: SystemTargetCommand {
    @Option(name: .customLong("id"), completion: vmID) var id: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "vm-pty-attach", shouldDisplay: false, helpNames: [])
}

/// Internal plumbing entry point, not part of the documented usage() surface.
struct VMPtyConnectCommand: SystemTargetCommand {
    @Option(name: .customLong("id"), completion: vmID) var id: String?
    @Option(name: .customLong("config"), completion: .file()) var config: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "vm-pty-connect", shouldDisplay: false, helpNames: [])
}

/// Hidden compatibility alias for workspaces created before the split helper was nested under `cmux vm`.
struct VMSSHAttachTopLevelCommand: SystemTargetCommand {
    @Option(name: .customLong("id"), completion: vmID) var id: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "vm-ssh-attach", shouldDisplay: false, helpNames: [])
}

struct TodoCommand: SystemTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "todo", helpNames: [])
}

struct CommentsCommand: LegacySystemCommand {
    @Option(name: .customLong("repo"), completion: .directory) var repo: String?
    @Flag(name: .customLong("all")) var all = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "comments", helpNames: [])
}

struct SidebarCommand: LegacySystemCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "sidebar", helpNames: [])
}

struct RightSidebarCommand: SystemTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Flag(name: .customLong("no-focus")) var noFocus = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "right-sidebar", helpNames: [])
}

struct SetAppFocusCommand: LegacySystemCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "set-app-focus", helpNames: [])
}

struct SimulateAppActiveCommand: LegacySystemCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "simulate-app-active", helpNames: [])
}

struct SimulateSidebarDragCommand: SystemTargetCommand {
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Option(name: .customLong("from")) var from: String?
    @Option(name: .customLong("to")) var to: String?
    @Option(name: .customLong("duration-ms")) var durationMS: Int?
    @Option(name: .customLong("steps")) var steps: Int?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "simulate-sidebar-drag", helpNames: [])
}

struct ProjectCommand: SystemTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "project", helpNames: [])
}

struct WindowNamespaceCommand: SystemTargetCommand {
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "window", helpNames: [])
}

struct CanvasCommand: SystemTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "canvas", helpNames: [])
}

struct LayoutCommand: SystemTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "layout", helpNames: [])
}
