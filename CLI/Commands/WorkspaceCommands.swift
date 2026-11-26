import ArgumentParser
import Foundation

struct ListWorkspacesCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list-workspaces", helpNames: [])
}

/// The flags `new-workspace` and `workspace create` share.
struct WorkspaceCreateOptions: ParsableArguments {
    @Option(name: .customLong("name")) var name: String?
    @Option(name: .customLong("description")) var description: String?
    @Option(name: .customLong("cwd"), completion: .directory) var cwd: String?
    @Option(name: .customLong("command")) var command: String?
    @Option(name: .customLong("env")) var environment: [String] = []
    @Option(name: .customLong("env-file"), completion: .file()) var environmentFiles: [String] = []
    @Option(name: .customLong("layout")) var layout: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Option(name: .customLong("focus")) var focus: String?
    @Option(name: .customLong("group")) var group: String?
    @Option(name: .customLong("group-placement"), completion: .list(["afterCurrent", "top", "end"])) var groupPlacement: String?
    @Option(name: .customLong("group-reference"), completion: .custom(CompletionCandidates.workspaces)) var groupReference: String?
}

struct NewWorkspaceCommand: SharedLegacyFacadeCommand {
    @OptionGroup var options: WorkspaceCreateOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "new-workspace", helpNames: [])
}

struct CloseWorkspaceCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Flag(name: .customLong("force")) var force = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "close-workspace", helpNames: [])
}

struct SelectWorkspaceCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "select-workspace", helpNames: [])
}

struct CurrentWorkspaceCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "current-workspace", helpNames: [])
}

struct RenameWorkspaceCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "rename-workspace", helpNames: [])
}

struct ReorderWorkspaceCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("index")) var index: String?
    @Option(name: [.customLong("before"), .customLong("before-workspace")], completion: .custom(CompletionCandidates.workspaces)) var before: String?
    @Option(name: [.customLong("after"), .customLong("after-workspace")], completion: .custom(CompletionCandidates.workspaces)) var after: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Flag(name: .customLong("dry-run")) var dryRun = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "reorder-workspace", helpNames: [])
}

struct ReorderWorkspacesCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("order"), completion: .custom(CompletionCandidates.workspaces)) var order: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Flag(name: .customLong("dry-run")) var dryRun = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "reorder-workspaces", helpNames: [])
}

struct MoveWorkspaceToWindowCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "move-workspace-to-window", helpNames: [])
}

/// `workspace` is a namespace (`runWorkspaceNamespace`). See SurfaceCommand's
/// comment: no catch-all argument alongside `subcommands`, and the read-only
/// `list` is the default subcommand so an unknown verb still reaches the legacy
/// parser's own diagnostic.
struct WorkspaceCommand: SharedLegacyFacadeCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace",
        subcommands: [
            WorkspaceListSubcommand.self,
            WorkspaceCreateSubcommand.self,
            WorkspaceEnvSubcommand.self,
            WorkspaceCloseSubcommand.self,
            WorkspaceRenameSubcommand.self,
            WorkspaceSelectSubcommand.self,
            WorkspaceStatusSubcommand.self,
            WorkspaceReconnectSubcommand.self,
            WorkspaceDisconnectSubcommand.self,
            WorkspaceLoadingSubcommand.self,
            WorkspaceGroupNamespaceCommand.self,
        ],
        defaultSubcommand: WorkspaceListSubcommand.self,
        helpNames: []
    )
}

struct WorkspaceListSubcommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list", helpNames: [])
}

struct WorkspaceCreateSubcommand: SharedLegacyFacadeCommand {
    @OptionGroup var options: WorkspaceCreateOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "create", helpNames: [])
}

struct WorkspaceEnvSubcommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Flag(name: .customLong("mask")) var mask = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "env", helpNames: [])
}

struct WorkspaceCloseSubcommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Flag(name: .customLong("force")) var force = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "close", helpNames: [])
}

struct WorkspaceRenameSubcommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Option(name: .customLong("title")) var title: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "rename", helpNames: [])
}

struct WorkspaceSelectSubcommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "select", helpNames: [])
}

struct WorkspaceStatusSubcommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Argument(completion: .list(["set", "cycle"])) var action: String?
    @Argument(completion: .list(["todo", "working", "needs-attention", "review", "done", "auto", "none"])) var lane: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "status", helpNames: [])
}

struct WorkspaceReconnectSubcommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "reconnect", helpNames: [])
}

struct WorkspaceDisconnectSubcommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "disconnect", helpNames: [])
}

struct WorkspaceLoadingSubcommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("id")) var id: String?
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Argument(completion: .list(["on", "off"])) var state: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "loading", helpNames: [])
}

struct WorkspaceActionCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("action")) var action: String?
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Option(name: .customLong("title")) var title: String?
    @Option(name: .customLong("color")) var color: String?
    @Option(name: .customLong("description")) var description: String?
    @Flag(name: .customLong("force")) var force = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "workspace-action", helpNames: [])
}

/// `workspace-group` and `workspace group` run the same `runWorkspaceGroup`, so
/// both declare the same subcommands; `list` is the read-only default.
struct WorkspaceGroupCommand: SharedLegacyFacadeCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace-group",
        subcommands: WorkspaceGroupSubcommands.all,
        defaultSubcommand: WorkspaceGroupListCommand.self,
        helpNames: []
    )
}

struct WorkspaceGroupNamespaceCommand: SharedLegacyFacadeCommand {
    static let configuration = CommandConfiguration(
        commandName: "group",
        subcommands: WorkspaceGroupSubcommands.all,
        defaultSubcommand: WorkspaceGroupListCommand.self,
        helpNames: []
    )
}

enum WorkspaceGroupSubcommands {
    static let all: [ParsableCommand.Type] = [
        WorkspaceGroupListCommand.self,
        WorkspaceGroupCreateCommand.self,
        WorkspaceGroupUngroupCommand.self,
        WorkspaceGroupDeleteCommand.self,
        WorkspaceGroupRenameCommand.self,
        WorkspaceGroupCollapseCommand.self,
        WorkspaceGroupExpandCommand.self,
        WorkspaceGroupPinCommand.self,
        WorkspaceGroupUnpinCommand.self,
        WorkspaceGroupAddCommand.self,
        WorkspaceGroupRemoveCommand.self,
        WorkspaceGroupSetAnchorCommand.self,
        WorkspaceGroupNewWorkspaceCommand.self,
        WorkspaceGroupSetColorCommand.self,
        WorkspaceGroupSetIconCommand.self,
        WorkspaceGroupMoveCommand.self,
        WorkspaceGroupFocusCommand.self,
    ]
}

/// The group selector (`--group <id>`, or the first positional) and window
/// context most `workspace-group` verbs accept; the positional falls into the
/// unrecognized-argument sink.
struct WorkspaceGroupTargetOptions: ParsableArguments {
    @Option(name: .customLong("group")) var group: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
}

struct WorkspaceGroupListCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list", helpNames: [])
}

struct WorkspaceGroupCreateCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("name")) var name: String?
    @Option(name: .customLong("cwd"), completion: .directory) var cwd: String?
    @Option(name: .customLong("from")) var from: String?
    @Option(name: .customLong("idempotency-key")) var idempotencyKey: String?
    @Option(name: .customLong("external-id")) var externalID: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "create", helpNames: [])
}

struct WorkspaceGroupUngroupCommand: SharedLegacyFacadeCommand {
    @OptionGroup var target: WorkspaceGroupTargetOptions
    @Flag(name: .customLong("remove-generated-anchor")) var removeGeneratedAnchor = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "ungroup", helpNames: [])
}

struct WorkspaceGroupDeleteCommand: SharedLegacyFacadeCommand {
    @OptionGroup var target: WorkspaceGroupTargetOptions
    @Flag(name: .customLong("close-workspaces")) var closeWorkspaces = false
    @Flag(name: .customLong("remove-generated-anchor")) var removeGeneratedAnchor = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "delete", helpNames: [])
}

struct WorkspaceGroupRenameCommand: SharedLegacyFacadeCommand {
    @OptionGroup var target: WorkspaceGroupTargetOptions
    @Option(name: .customLong("name")) var name: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "rename", helpNames: [])
}

struct WorkspaceGroupCollapseCommand: SharedLegacyFacadeCommand {
    @OptionGroup var target: WorkspaceGroupTargetOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "collapse", helpNames: [])
}

struct WorkspaceGroupExpandCommand: SharedLegacyFacadeCommand {
    @OptionGroup var target: WorkspaceGroupTargetOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "expand", helpNames: [])
}

struct WorkspaceGroupPinCommand: SharedLegacyFacadeCommand {
    @OptionGroup var target: WorkspaceGroupTargetOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "pin", helpNames: [])
}

struct WorkspaceGroupUnpinCommand: SharedLegacyFacadeCommand {
    @OptionGroup var target: WorkspaceGroupTargetOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "unpin", helpNames: [])
}

struct WorkspaceGroupAddCommand: SharedLegacyFacadeCommand {
    @OptionGroup var target: WorkspaceGroupTargetOptions
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "add", helpNames: [])
}

struct WorkspaceGroupRemoveCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "remove", helpNames: [])
}

struct WorkspaceGroupSetAnchorCommand: SharedLegacyFacadeCommand {
    @OptionGroup var target: WorkspaceGroupTargetOptions
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "set-anchor", helpNames: [])
}

struct WorkspaceGroupNewWorkspaceCommand: SharedLegacyFacadeCommand {
    @OptionGroup var target: WorkspaceGroupTargetOptions
    @Option(name: .customLong("placement")) var placement: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "new-workspace", helpNames: [])
}

struct WorkspaceGroupSetColorCommand: SharedLegacyFacadeCommand {
    @OptionGroup var target: WorkspaceGroupTargetOptions
    @Option(name: .customLong("hex")) var hex: String?
    @Option(name: .customLong("color")) var color: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "set-color", helpNames: [])
}

struct WorkspaceGroupSetIconCommand: SharedLegacyFacadeCommand {
    @OptionGroup var target: WorkspaceGroupTargetOptions
    @Option(name: .customLong("symbol")) var symbol: String?
    @Option(name: .customLong("icon")) var icon: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "set-icon", helpNames: [])
}

struct WorkspaceGroupMoveCommand: SharedLegacyFacadeCommand {
    @OptionGroup var target: WorkspaceGroupTargetOptions
    @Option(name: .customLong("to-index")) var toIndex: String?
    @Option(name: .customLong("before")) var before: String?
    @Option(name: .customLong("after")) var after: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "move", helpNames: [])
}

struct WorkspaceGroupFocusCommand: SharedLegacyFacadeCommand {
    @OptionGroup var target: WorkspaceGroupTargetOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "focus", helpNames: [])
}

struct MoveTabToNewWorkspaceCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("tab"), completion: .custom(CompletionCandidates.tabs)) var tab: String?
    @Option(name: .customLong("surface"), completion: .custom(CompletionCandidates.surfaces)) var surface: String?
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Option(name: .customLong("title")) var title: String?
    @Option(name: .customLong("focus")) var focus: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "move-tab-to-new-workspace", helpNames: [])
}
