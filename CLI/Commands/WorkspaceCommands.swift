import ArgumentParser
import Foundation

/// Routes workspace facade declarations through the established CLI implementation.
private protocol LegacyWorkspaceCommand: ParsableCommand {}

extension LegacyWorkspaceCommand {
    func run() throws {
        try GlobalOptions().makeCLI().run()
    }
}

struct ListWorkspacesCommand: LegacyWorkspaceCommand {
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    static let configuration = CommandConfiguration(commandName: "list-workspaces", helpNames: [])
}

struct NewWorkspaceCommand: LegacyWorkspaceCommand {
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
    static let configuration = CommandConfiguration(commandName: "new-workspace", helpNames: [])
}

struct CloseWorkspaceCommand: LegacyWorkspaceCommand {
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    static let configuration = CommandConfiguration(commandName: "close-workspace", helpNames: [])
}

struct SelectWorkspaceCommand: LegacyWorkspaceCommand {
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    static let configuration = CommandConfiguration(commandName: "select-workspace", helpNames: [])
}

struct CurrentWorkspaceCommand: LegacyWorkspaceCommand {
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    static let configuration = CommandConfiguration(commandName: "current-workspace", helpNames: [])
}

struct RenameWorkspaceCommand: LegacyWorkspaceCommand {
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Argument(parsing: .allUnrecognized) var title: [String] = []
    static let configuration = CommandConfiguration(commandName: "rename-workspace", helpNames: [])
}

struct ReorderWorkspaceCommand: LegacyWorkspaceCommand {
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("index")) var index: Int?
    @Option(name: [.customLong("before"), .customLong("before-workspace")], completion: .custom(CompletionCandidates.workspaces)) var before: String?
    @Option(name: [.customLong("after"), .customLong("after-workspace")], completion: .custom(CompletionCandidates.workspaces)) var after: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Flag(name: .customLong("dry-run")) var dryRun = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "reorder-workspace", helpNames: [])
}

struct ReorderWorkspacesCommand: LegacyWorkspaceCommand {
    @Option(name: .customLong("order"), completion: .custom(CompletionCandidates.workspaces)) var order: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Flag(name: .customLong("dry-run")) var dryRun = false
    static let configuration = CommandConfiguration(commandName: "reorder-workspaces", helpNames: [])
}

struct MoveWorkspaceToWindowCommand: LegacyWorkspaceCommand {
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    static let configuration = CommandConfiguration(commandName: "move-workspace-to-window", helpNames: [])
}

struct WorkspaceCommand: LegacyWorkspaceCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "workspace", helpNames: [])
}

struct WorkspaceActionCommand: LegacyWorkspaceCommand {
    @Option(name: .customLong("action")) var action: String?
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Option(name: .customLong("title")) var title: String?
    @Option(name: .customLong("color")) var color: String?
    @Option(name: .customLong("description")) var description: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "workspace-action", helpNames: [])
}

struct WorkspaceGroupCommand: LegacyWorkspaceCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "workspace-group", helpNames: [])
}

struct MoveTabToNewWorkspaceCommand: LegacyWorkspaceCommand {
    @Option(name: .customLong("tab"), completion: .custom(CompletionCandidates.tabs)) var tab: String?
    @Option(name: .customLong("surface"), completion: .custom(CompletionCandidates.surfaces)) var surface: String?
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows)) var window: String?
    @Option(name: .customLong("title")) var title: String?
    @Option(name: .customLong("focus")) var focus: String?
    static let configuration = CommandConfiguration(commandName: "move-tab-to-new-workspace", helpNames: [])
}
