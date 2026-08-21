import ArgumentParser
import Foundation

/// Routes VM and remote facade declarations through the established CLI implementation.
private protocol LegacyVMCommand: ParsableCommand {}

extension LegacyVMCommand {
    func run() throws {
        try GlobalOptions().makeCLI().run()
    }
}

private protocol VMIDCommand: LegacyVMCommand {}

extension VMIDCommand {
    static var vmID: CompletionKind {
        .custom(CompletionCandidates.vms)
    }
}

struct VMCommand: LegacyVMCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []

    static let configuration = CommandConfiguration(
        commandName: "vm",
        aliases: ["cloud"],
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
        ],
        defaultSubcommand: VMListCommand.self,
        helpNames: []
    )
}

struct VMBaseCommand: LegacyVMCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
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
    @Flag(name: [.customLong("detach"), .customShort("d")]) var detach = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "open", helpNames: [])
}

struct VMBaseResetCommand: LegacyVMCommand {
    @Option(name: .customLong("reason")) var reason: String?
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Flag(name: [.customLong("detach"), .customShort("d")]) var detach = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "reset", helpNames: [])
}

struct VMNewCommand: LegacyVMCommand {
    @Option(name: .customLong("image")) var image: String?
    @Option(name: .customLong("provider")) var provider: String?
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Flag(name: [.customLong("detach"), .customShort("d")]) var detach = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "new", aliases: ["create"], helpNames: [])
}

struct VMListCommand: LegacyVMCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "ls", aliases: ["list"], helpNames: [])
}

struct VMStatusCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    static let configuration = CommandConfiguration(commandName: "status", aliases: ["info"], helpNames: [])
}

struct VMSnapshotCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Option(name: .customLong("name")) var name: String?
    static let configuration = CommandConfiguration(commandName: "snapshot", aliases: ["checkpoint"], helpNames: [])
}

struct VMForkCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Option(name: .customLong("name")) var name: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Flag(name: [.customLong("detach"), .customShort("d")]) var detach = false
    static let configuration = CommandConfiguration(commandName: "fork", helpNames: [])
}

struct VMRestoreCommand: LegacyVMCommand {
    @Argument var snapshotID: String?
    @Option(name: .customLong("provider")) var provider: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Flag(name: [.customLong("detach"), .customShort("d")]) var detach = false
    static let configuration = CommandConfiguration(commandName: "restore", helpNames: [])
}

struct VMRemoveCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    static let configuration = CommandConfiguration(commandName: "rm", aliases: ["destroy", "delete"], helpNames: [])
}

struct VMExecCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Argument(parsing: .captureForPassthrough) var command: [String] = []
    static let configuration = CommandConfiguration(commandName: "exec", helpNames: [])
}

struct VMShellCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    static let configuration = CommandConfiguration(commandName: "shell", aliases: ["attach"], helpNames: [])
}

struct VMSSHCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    static let configuration = CommandConfiguration(commandName: "ssh", helpNames: [])
}

struct VMSSHInfoCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    static let configuration = CommandConfiguration(commandName: "ssh-info", helpNames: [])
}

struct VMToolsCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    static let configuration = CommandConfiguration(commandName: "tools", aliases: ["tool-inspector"], helpNames: [])
}

struct VMPortsCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    static let configuration = CommandConfiguration(commandName: "ports", helpNames: [])
}

struct VMHandoffCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    static let configuration = CommandConfiguration(commandName: "handoff", helpNames: [])
}

struct VMPromoteTemplateCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    static let configuration = CommandConfiguration(commandName: "promote-template", helpNames: [])
}

/// Retains the undocumented legacy command so VM routing remains transparent.
struct VMSSHAttachCommand: VMIDCommand {
    @Argument(completion: vmID) var id: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "ssh-attach", shouldDisplay: false, helpNames: [])
}

struct RemotesCommand: LegacyVMCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(
        commandName: "remotes",
        aliases: ["remote"],
        subcommands: [RemotesListCommand.self, RemotesAddCommand.self, RemotesRemoveCommand.self],
        defaultSubcommand: RemotesListCommand.self,
        helpNames: []
    )
}

struct RemotesListCommand: LegacyVMCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list", aliases: ["ls"], helpNames: [])
}

struct RemotesAddCommand: LegacyVMCommand {
    @Argument var name: String?
    @Option(name: .customLong("route")) var routes: [String] = []
    @Option(name: .customLong("tag")) var tag: String?
    static let configuration = CommandConfiguration(commandName: "add", helpNames: [])
}

struct RemotesRemoveCommand: LegacyVMCommand {
    @Argument var target: String?
    static let configuration = CommandConfiguration(commandName: "remove", aliases: ["rm", "delete"], helpNames: [])
}

struct RemoteDaemonStatusCommand: LegacyVMCommand {
    @Option(name: .customLong("os")) var operatingSystem: String?
    @Option(name: .customLong("arch")) var architecture: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []

    // The legacy parser deliberately prints status for --help.
    static let configuration = CommandConfiguration(commandName: "remote-daemon-status", helpNames: [])
}
