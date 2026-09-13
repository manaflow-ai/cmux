import ArgumentParser
import Foundation

/// Routes VM and remote facade declarations through the established CLI implementation.
private protocol LegacyVMCommand: SharedLegacyFacadeCommand {}

private protocol VMIDCommand: LegacyVMCommand {}

extension VMIDCommand {
    static var vmID: CompletionKind {
        .custom(CompletionCandidates.vms)
    }
}

struct VMCommand: LegacyVMCommand {
    // No catch-all argument here: ArgumentParser already generates a rest-argument
    // spec to dispatch into `subcommands`, and a second one on this struct produces
    // an invalid duplicate `_arguments` spec in the generated zsh completion script.
    // `defaultSubcommand` absorbs anything that doesn't name a declared subcommand.

    /// The flag spelling of `cmux vm guide`. The default subcommand's `run()`
    /// hands the raw argv to the legacy runner, which serves the guide.
    @Flag(name: .customLong("skill")) var skill = false

    static let configuration = CommandConfiguration(
        commandName: "vm",
        subcommands: [
            VMBaseCommand.self,
            VMNewCommand.self,
            VMListCommand.self,
            VMStatusCommand.self,
            VMSnapshotCommand.self,
            VMForkCommand.self,
            VMRestoreCommand.self,
            VMRemoveCommand.self,
            VMExecCommand.self,
            VMShellCommand.self,
            VMSSHCommand.self,
            VMSSHInfoCommand.self,
            VMToolsCommand.self,
            VMPortsCommand.self,
            VMHandoffCommand.self,
            VMPromoteTemplateCommand.self,
            VMSSHAttachCommand.self,
            VMGuideCommand.self,
            VMDomainsCommand.self,
            VMWorkspaceCommand.self,
            VMTerminalCommand.self,
            VMLayoutCommand.self,
            VMEnvCommand.self,
            VMTabCommand.self,
            VMPromptCommand.self,
            VMTreeCommand.self,
            VMSelfCommand.self,
            VMStatsCommand.self,
            VMResizeCommand.self,
            VMRenameCommand.self,
            VMPauseCommand.self,
            VMResumeCommand.self,
            VMTuiCommand.self,
            VMDesktopCommand.self,
            VMOpenCommand.self,
            VMRunCommand.self,
            VMRouteCommand.self,
            VMAgentCommand.self,
            VMDevCommand.self,
            VMPushCommand.self,
            VMPullCommand.self,
            VMWaitCommand.self,
        ],
        defaultSubcommand: VMListCommand.self,
        helpNames: [],
        aliases: ["cloud"]
    )
}

struct VMBaseCommand: LegacyVMCommand {
    // See VMCommand's comment: no catch-all argument alongside `subcommands`.
    static let configuration = CommandConfiguration(
        commandName: "base",
        subcommands: [VMBaseOpenCommand.self, VMBaseResetCommand.self],
        defaultSubcommand: VMBaseOpenCommand.self,
        helpNames: []
    )
}

struct VMBaseOpenCommand: LegacyVMCommand {
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Option(name: .customLong("focus")) var focus: String?
    // The image-kind flags. The legacy runner rejects a conflicting pair itself,
    // so they stay independent declarations rather than an exclusive group that
    // would fail before `run()` delegates.
    @Flag(name: .customLong("base")) var base = false
    @Flag(name: .customLong("desktop")) var desktop = false
    @Flag(name: .customLong("no-desktop")) var noDesktop = false
    @Flag(name: [.customLong("detach"), .customShort("d")]) var detach = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "open", helpNames: [])
}

struct VMBaseResetCommand: LegacyVMCommand {
    @Option(name: .customLong("reason")) var reason: String?
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    // See VMBaseOpenCommand: the kind flags are validated by the legacy runner.
    @Flag(name: .customLong("base")) var base = false
    @Flag(name: .customLong("desktop")) var desktop = false
    @Flag(name: .customLong("no-desktop")) var noDesktop = false
    @Flag(name: [.customLong("detach"), .customShort("d")]) var detach = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "reset", helpNames: [])
}

struct VMNewCommand: LegacyVMCommand {
    @Option(name: .customLong("image")) var image: String?
    @Option(name: .customLong("provider")) var provider: String?
    @Option(name: .customLong("name")) var name: String?
    // `String?`, not an enum: the legacy runner accepts raw megabytes as well as
    // the named sizes, and owns the "unknown size" diagnostic.
    @Option(name: .customLong("size"), completion: .list(["4g", "8g", "16g", "24g", "32g", "64g"]))
    var size: String?
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Option(name: .customLong("focus")) var focus: String?
    // See VMBaseOpenCommand: the kind flags are validated by the legacy runner.
    @Flag(name: .customLong("base")) var base = false
    @Flag(name: .customLong("desktop")) var desktop = false
    @Flag(name: .customLong("no-desktop")) var noDesktop = false
    @Flag(name: [.customLong("detach"), .customShort("d")]) var detach = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "new", helpNames: [], aliases: ["create"])
}

struct VMListCommand: LegacyVMCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "ls", helpNames: [], aliases: ["list"])
}

struct VMStatusCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "status", helpNames: [], aliases: ["info"])
}

struct VMSnapshotCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Option(name: .customLong("name")) var name: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "snapshot", helpNames: [], aliases: ["checkpoint"])
}

struct VMForkCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Option(name: .customLong("name")) var name: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Flag(name: [.customLong("detach"), .customShort("d")]) var detach = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "fork", helpNames: [])
}

struct VMRestoreCommand: LegacyVMCommand {
    @Argument var snapshotID: String?
    @Option(name: .customLong("provider")) var provider: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Flag(name: [.customLong("detach"), .customShort("d")]) var detach = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "restore", helpNames: [])
}

struct VMRemoveCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "rm", helpNames: [], aliases: ["destroy", "delete"])
}

struct VMExecCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Argument(parsing: .captureForPassthrough) var command: [String] = []
    static let configuration = CommandConfiguration(commandName: "exec", helpNames: [])
}

struct VMShellCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "shell", helpNames: [], aliases: ["attach"])
}

struct VMSSHCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "ssh", helpNames: [])
}

struct VMSSHInfoCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "ssh-info", helpNames: [])
}

struct VMToolsCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "tools", helpNames: [], aliases: ["tool-inspector"])
}

struct VMPortsCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "ports", helpNames: [])
}

struct VMHandoffCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "handoff", helpNames: [])
}

struct VMPromoteTemplateCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "promote-template", helpNames: [])
}

/// Retains the undocumented legacy command so VM routing remains transparent.
/// `runVMSSHAttach` reads the machine from `--id` and rejects every positional,
/// so this declares the option rather than the positional the other VM leaves
/// use: the startup command cmux generates for a split attach spells it
/// `vm ssh-attach --id <vm> --default-freestyle-sshd`.
struct VMSSHAttachCommand: VMIDCommand {
    @Option(name: .customLong("id"), completion: vmID) var id: String?
    @Flag(name: .customLong("default-freestyle-sshd")) var usesDefaultFreestyleSSHD = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "ssh-attach", shouldDisplay: false, helpNames: [])
}

/// Served by `runGuideCommand` ahead of the vm verb switch, like `vm --skill`.
struct VMGuideCommand: LegacyVMCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "guide", helpNames: [])
}

struct VMPromptCommand: LegacyVMCommand {
    @Option(name: .customLong("open"), completion: .list(["claude", "codex", "opencode"])) var open: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "prompt", helpNames: [], aliases: ["skill"])
}

struct VMTreeCommand: VMIDCommand {
    // `local` is also accepted in this position; the VM ids are what varies.
    @Argument(completion: vmID) var machine: String?
    @Flag(name: .customLong("refresh")) var refresh = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "tree", helpNames: [])
}

struct VMSelfCommand: VMIDCommand {
    @Argument(completion: vmID) var machine: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "self", helpNames: [])
}

struct VMStatsCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "stats", helpNames: [], aliases: ["top"])
}

struct VMResizeCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Option(name: .customLong("cpu")) var cpu: String?
    @Option(name: .customLong("memory")) var memory: String?
    @Option(name: .customLong("disk")) var disk: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "resize", helpNames: [])
}

struct VMRenameCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Flag(name: .customLong("clear")) var clear = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "rename", helpNames: [])
}

struct VMPauseCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "pause", helpNames: [])
}

struct VMResumeCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "resume", helpNames: [])
}

struct VMTuiCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "tui", helpNames: [])
}

struct VMDesktopCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "desktop", helpNames: [], aliases: ["vnc"])
}

struct VMOpenCommand: VMIDCommand {
    // A bare machine, or a `machine/ws[/term[/tab]]` / `machine:port/<n>` address
    // from `vm tree`; the machine is the part completion can supply.
    @Argument(completion: vmID) var target: String?
    @Flag(name: .customLong("print")) var printsURL = false
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("focus"), completion: .list(["true", "false"])) var focus: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "open", helpNames: [], aliases: ["port"])
}

struct VMRunCommand: VMIDCommand {
    @Flag(name: .customLong("sync")) var sync = false
    @Flag(name: .customLong("new")) var new = false
    @Flag(name: .customLong("wait")) var wait = false
    @Flag(name: .customLong("output")) var output = false
    @Option(name: .customLong("pull")) var pull: String?
    @Option(name: .customLong("machine"), completion: vmID) var machine: String?
    @Option(name: .customLong("size")) var size: String?
    @Option(name: .customLong("timeout")) var timeout: String?
    @Argument(parsing: .captureForPassthrough) var command: [String] = []
    static let configuration = CommandConfiguration(commandName: "run", helpNames: [])
}

struct VMRouteCommand: LegacyVMCommand {
    @Option(name: .customLong("cwd"), completion: .directory) var cwd: String?
    @Option(name: .customLong("size")) var size: String?
    @Flag(name: .customLong("new")) var new = false
    @Flag(name: .customLong("provision")) var provision = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "route", helpNames: [])
}

struct VMAgentCommand: VMIDCommand {
    @Option(name: .customLong("agent"), completion: .list(["claude", "codex", "opencode", "pi"])) var agent: String?
    @Option(name: .customLong("machine"), completion: vmID) var machine: String?
    @Option(name: .customLong("cwd"), completion: .directory) var cwd: String?
    @Option(name: .customLong("name")) var name: String?
    @Option(name: .customLong("remote-workspace")) var remoteWorkspace: String?
    @Option(name: .customLong("size")) var size: String?
    @Option(name: .customLong("timeout")) var timeout: String?
    @Flag(name: .customLong("sync")) var sync = false
    @Flag(name: .customLong("no-open")) var noOpen = false
    @Flag(name: .customLong("new")) var new = false
    @Flag(name: .customLong("wait")) var wait = false
    @Flag(name: .customLong("output")) var output = false
    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "agent", helpNames: [])
}

struct VMDevCommand: VMIDCommand {
    @Argument(completion: vmID) var machine: String?
    @Argument(completion: .directory) var localDirectory: String?
    @Option(name: .customLong("name")) var name: String?
    @Option(name: .customLong("layout"), completion: .file()) var layout: String?
    @Option(name: .customLong("command")) var command: String?
    @Option(name: .customLong("remote")) var remote: String?
    @Option(name: .customLong("port")) var port: String?
    @Flag(name: .customLong("sync")) var sync = false
    @Flag(name: .customLong("no-sync")) var noSync = false
    @Flag(name: .customLong("no-open")) var noOpen = false
    @Flag(name: .customLong("dry-run")) var dryRun = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "dev", helpNames: [])
}

struct VMPushCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Argument(completion: .file()) var localPath: String?
    @Option(name: .customLong("exclude")) var excludes: [String] = []
    @Flag(name: .customLong("no-default-excludes")) var noDefaultExcludes = false
    @Flag(name: .customLong("secret")) var secret = false
    @Option(name: .customLong("mode")) var mode: String?
    @Flag(name: .customLong("watch")) var watch = false
    @Option(name: .customLong("interval")) var interval: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "push", helpNames: [], aliases: ["upload"])
}

struct VMPullCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "pull", helpNames: [], aliases: ["download"])
}

struct VMWaitCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Option(name: .customLong("timeout")) var timeout: String?
    @Flag(name: .customLong("wake")) var wake = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "wait", helpNames: [])
}

// The verb families below dispatch on a sub-verb, so each is a namespace whose
// `defaultSubcommand` absorbs an unknown sub-verb for the runner's own diagnostic.
// See VMCommand's comment: no catch-all argument alongside `subcommands`.

struct VMDomainsCommand: LegacyVMCommand {
    static let configuration = CommandConfiguration(
        commandName: "domains",
        subcommands: [
            VMDomainsListCommand.self,
            VMDomainsZonesCommand.self,
            VMDomainsPublishCommand.self,
            VMDomainsVerifyCommand.self,
            VMDomainsAccessCommand.self,
            VMDomainsGrantCommand.self,
            VMDomainsUngrantCommand.self,
            VMDomainsGrantsCommand.self,
            VMDomainsRemoveCommand.self,
        ],
        defaultSubcommand: VMDomainsListCommand.self,
        helpNames: []
    )

    static let accessLevels = ["personal", "team", "public"]
}

struct VMDomainsListCommand: LegacyVMCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list", helpNames: [], aliases: ["ls"])
}

struct VMDomainsZonesCommand: LegacyVMCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "zones", helpNames: [], aliases: ["custom"])
}

struct VMDomainsPublishCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Argument var port: String?
    @Flag(name: .customLong("yes")) var yes = false
    @Option(name: .customLong("org-slug")) var orgSlug: String?
    @Option(name: .customLong("domain")) var domain: String?
    @Option(name: .customLong("access"), completion: .list(VMDomainsCommand.accessLevels)) var access: String?
    @Option(name: .customLong("team")) var team: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "publish", helpNames: [])
}

struct VMDomainsVerifyCommand: LegacyVMCommand {
    @Argument var domain: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "verify", helpNames: [])
}

struct VMDomainsAccessCommand: LegacyVMCommand {
    @Argument var target: String?
    @Argument(completion: .list(VMDomainsCommand.accessLevels)) var level: String?
    @Flag(name: .customLong("yes")) var yes = false
    @Option(name: .customLong("team")) var team: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "access", helpNames: [])
}

struct VMDomainsGrantCommand: LegacyVMCommand {
    @Argument var hostname: String?
    @Argument var email: String?
    @Option(name: .customLong("expires")) var expires: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "grant", helpNames: [])
}

struct VMDomainsUngrantCommand: LegacyVMCommand {
    @Argument var hostname: String?
    @Argument var email: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "ungrant", helpNames: [])
}

struct VMDomainsGrantsCommand: LegacyVMCommand {
    @Argument var hostname: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "grants", helpNames: [])
}

struct VMDomainsRemoveCommand: LegacyVMCommand {
    @Argument var hostname: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "rm", helpNames: [], aliases: ["remove", "delete"])
}

struct VMWorkspaceCommand: LegacyVMCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace",
        subcommands: [
            VMWorkspaceNewCommand.self,
            VMWorkspaceOpenCommand.self,
            VMWorkspaceRenameCommand.self,
            VMWorkspaceCloseCommand.self,
            VMWorkspaceRemoveCommand.self,
        ],
        defaultSubcommand: VMWorkspaceNewCommand.self,
        helpNames: []
    )
}

struct VMWorkspaceNewCommand: VMIDCommand {
    @Argument(completion: vmID) var machine: String?
    @Option(name: .customLong("name")) var name: String?
    @Flag(name: .customLong("reuse")) var reuse = false
    @Flag(name: .customLong("no-open")) var noOpen = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "new", helpNames: [])
}

struct VMWorkspaceOpenCommand: VMIDCommand {
    @Argument(completion: vmID) var machine: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("pane"), completion: paneCompletion) var pane: String?
    @Flag(name: .customLong("here")) var here = false
    @Flag(name: .customLong("tabs")) var tabs = false
    // At most one direction, and only with --pane; the runner validates both.
    @Flag(name: .customLong("left")) var left = false
    @Flag(name: .customLong("right")) var right = false
    @Flag(name: .customLong("up")) var up = false
    @Flag(name: .customLong("down")) var down = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "open", helpNames: [])
}

struct VMWorkspaceRenameCommand: VMIDCommand {
    @Argument(completion: vmID) var machine: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "rename", helpNames: [])
}

struct VMWorkspaceCloseCommand: VMIDCommand {
    @Argument(completion: vmID) var machine: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "close", helpNames: [])
}

struct VMWorkspaceRemoveCommand: VMIDCommand {
    @Argument(completion: vmID) var machine: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "rm", helpNames: [], aliases: ["delete"])
}

struct VMTerminalCommand: LegacyVMCommand {
    static let configuration = CommandConfiguration(
        commandName: "terminal",
        subcommands: [
            VMTerminalCloseCommand.self,
            VMTerminalSendCommand.self,
            VMTerminalReadCommand.self,
            VMTerminalRenameCommand.self,
            VMTerminalWaitCommand.self,
            VMTerminalWaitExitCommand.self,
            VMTerminalOutputCommand.self,
        ],
        defaultSubcommand: VMTerminalCloseCommand.self,
        helpNames: []
    )
}

struct VMTerminalCloseCommand: VMIDCommand {
    @Argument(completion: vmID) var machine: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "close", helpNames: [])
}

struct VMTerminalSendCommand: VMIDCommand {
    @Argument(completion: vmID) var machine: String?
    @Option(name: .customLong("keys")) var keys: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "send", helpNames: [], aliases: ["write"])
}

struct VMTerminalReadCommand: VMIDCommand {
    @Argument(completion: vmID) var machine: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "read", helpNames: [], aliases: ["screen"])
}

struct VMTerminalRenameCommand: VMIDCommand {
    @Argument(completion: vmID) var machine: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "rename", helpNames: [])
}

struct VMTerminalWaitCommand: VMIDCommand {
    @Argument(completion: vmID) var machine: String?
    @Option(name: .customLong("pattern")) var pattern: String?
    @Option(name: .customLong("timeout")) var timeout: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "wait", helpNames: [])
}

struct VMTerminalWaitExitCommand: VMIDCommand {
    @Argument(completion: vmID) var machine: String?
    @Option(name: .customLong("timeout")) var timeout: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "wait-exit", helpNames: [])
}

struct VMTerminalOutputCommand: VMIDCommand {
    @Argument(completion: vmID) var machine: String?
    @Option(name: .customLong("after")) var after: String?
    @Option(name: .customLong("max-bytes")) var maxBytes: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "output", helpNames: [])
}

struct VMLayoutCommand: LegacyVMCommand {
    static let configuration = CommandConfiguration(
        commandName: "layout",
        subcommands: [VMLayoutExportCommand.self, VMLayoutApplyCommand.self],
        defaultSubcommand: VMLayoutExportCommand.self,
        helpNames: []
    )
}

struct VMLayoutExportCommand: VMIDCommand {
    @Argument(completion: vmID) var machine: String?
    @Flag(name: .customLong("raw")) var raw = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "export", helpNames: [], aliases: ["get", "show"])
}

struct VMLayoutApplyCommand: VMIDCommand {
    @Argument(completion: vmID) var machine: String?
    @Argument(completion: .file()) var file: String?
    @Option(name: .customLong("workspace")) var workspace: String?
    @Option(name: .customLong("name")) var name: String?
    @Option(name: .customLong("cwd"), completion: .directory) var cwd: String?
    @Option(name: .customLong("from-saved")) var fromSaved: String?
    @Flag(name: .customLong("open")) var open = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "apply", helpNames: [], aliases: ["set"])
}

struct VMEnvCommand: LegacyVMCommand {
    static let configuration = CommandConfiguration(
        commandName: "env",
        subcommands: [VMEnvSetCommand.self, VMEnvListCommand.self, VMEnvRemoveCommand.self],
        defaultSubcommand: VMEnvListCommand.self,
        helpNames: []
    )
}

struct VMEnvSetCommand: VMIDCommand {
    @Argument(completion: vmID) var machine: String?
    @Option(name: .customLong("from-file"), completion: .file()) var fromFiles: [String] = []
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "set", helpNames: [], aliases: ["add"])
}

struct VMEnvListCommand: VMIDCommand {
    @Argument(completion: vmID) var machine: String?
    @Flag(name: .customLong("show")) var show = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "ls", helpNames: [], aliases: ["list"])
}

struct VMEnvRemoveCommand: VMIDCommand {
    @Argument(completion: vmID) var machine: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "rm", helpNames: [], aliases: ["remove", "unset"])
}

struct VMTabCommand: LegacyVMCommand {
    static let configuration = CommandConfiguration(
        commandName: "tab",
        subcommands: [VMTabRenameCommand.self],
        defaultSubcommand: VMTabRenameCommand.self,
        helpNames: []
    )
}

struct VMTabRenameCommand: VMIDCommand {
    @Argument(completion: vmID) var machine: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "rename", helpNames: [])
}

struct RemotesCommand: LegacyVMCommand {
    // See VMCommand's comment: no catch-all argument alongside `subcommands`.
    static let configuration = CommandConfiguration(
        commandName: "remotes",
        subcommands: [RemotesListCommand.self, RemotesAddCommand.self, RemotesRemoveCommand.self],
        defaultSubcommand: RemotesListCommand.self,
        helpNames: [],
        aliases: ["remote"]
    )
}

struct RemotesListCommand: LegacyVMCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list", helpNames: [], aliases: ["ls"])
}

struct RemotesAddCommand: LegacyVMCommand {
    @Argument var name: String?
    @Option(name: .customLong("route")) var routes: [String] = []
    @Option(name: .customLong("tag")) var tag: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "add", helpNames: [])
}

struct RemotesRemoveCommand: LegacyVMCommand {
    @Argument var target: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "remove", helpNames: [], aliases: ["rm", "delete"])
}

struct RemoteDaemonStatusCommand: LegacyVMCommand {
    @Option(name: .customLong("os")) var operatingSystem: String?
    @Option(name: .customLong("arch")) var architecture: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []

    // The legacy parser deliberately prints status for --help.
    static let configuration = CommandConfiguration(commandName: "remote-daemon-status", helpNames: [])
}
