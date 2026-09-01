import ArgumentParser
import Foundation

struct ListWorkspacesCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list-workspaces", helpNames: [])
}

struct NewWorkspaceCommand: SharedLegacyFacadeCommand {
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
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "new-workspace", helpNames: [])
}

struct CloseWorkspaceCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
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

struct WorkspaceCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "workspace", helpNames: [])
}

struct WorkspaceActionCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("action")) var action: String?
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Option(name: .customLong("title")) var title: String?
    @Option(name: .customLong("color")) var color: String?
    @Option(name: .customLong("description")) var description: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "workspace-action", helpNames: [])
}

struct WorkspaceGroupCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "workspace-group", helpNames: [])
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
