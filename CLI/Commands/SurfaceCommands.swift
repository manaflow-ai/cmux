import ArgumentParser
import Foundation

struct NewPaneCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("type"), completion: .list(["terminal", "browser", "simulator"])) var type: String?
    @Option(name: .customLong("direction"), completion: .list(["left", "right", "up", "down"])) var direction: String?
    @Option(name: .customLong("placement"), completion: .list(["workspace", "dock"])) var placement: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Option(name: .customLong("url")) var url: String?
    @Option(name: .customLong("profile")) var profile: String?
    @Option(name: .customLong("focus")) var focus: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "new-pane", helpNames: [])
}

struct NewSplitCommand: SharedLegacyFacadeCommand {
    @Argument(completion: .list(["left", "right", "up", "down"])) var direction: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("panel"), completion: .custom(CompletionCandidates.panels)) var panelID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Option(name: .customLong("focus")) var focus: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "new-split", helpNames: [])
}

struct NewSurfaceCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("type"), completion: .list(["terminal", "browser", "simulator", "agent-session"])) var type: String?
    @Option(name: .customLong("pane"), completion: paneCompletion) var paneID: String?
    @Option(name: .customLong("placement"), completion: .list(["workspace", "dock"])) var placement: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Option(name: .customLong("url")) var url: String?
    @Option(name: [.customLong("provider"), .customLong("provider-id")]) var provider: String?
    @Option(name: [.customLong("renderer"), .customLong("renderer-kind")]) var renderer: String?
    @Option(name: [.customLong("working-directory"), .customLong("cwd")], completion: .directory) var workingDirectory: String?
    @Option(name: .customLong("focus")) var focus: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "new-surface", helpNames: [])
}

struct CloseSurfaceCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("panel"), completion: .custom(CompletionCandidates.panels)) var panelID: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "close-surface", helpNames: [])
}

struct MoveSurfaceCommand: SharedLegacyFacadeCommand {
    @Argument(completion: surfaceCompletion) var target: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("pane"), completion: paneCompletion) var paneID: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Option(name: [.customLong("before"), .customLong("before-surface")], completion: surfaceCompletion) var before: String?
    @Option(name: [.customLong("after"), .customLong("after-surface")], completion: surfaceCompletion) var after: String?
    @Option(name: .customLong("index")) var index: String?
    @Option(name: .customLong("focus")) var focus: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "move-surface", helpNames: [])
}

struct SplitOffCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("panel"), completion: .custom(CompletionCandidates.panels)) var panelID: String?
    @Argument(completion: .list(["left", "right", "up", "down"])) var direction: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Option(name: .customLong("focus")) var focus: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "split-off", helpNames: [])
}

struct ReorderSurfaceCommand: SharedLegacyFacadeCommand {
    @Argument(completion: surfaceCompletion) var target: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Option(name: [.customLong("before"), .customLong("before-surface")], completion: surfaceCompletion) var before: String?
    @Option(name: [.customLong("after"), .customLong("after-surface")], completion: surfaceCompletion) var after: String?
    @Option(name: .customLong("index")) var index: String?
    @Option(name: .customLong("focus")) var focus: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "reorder-surface", helpNames: [])
}

struct FocusPaneCommand: SharedLegacyFacadeCommand {
    @Argument(completion: paneCompletion) var target: String?
    @Option(name: .customLong("pane"), completion: paneCompletion) var paneID: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "focus-pane", helpNames: [])
}

struct FocusPanelCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("panel"), completion: .custom(CompletionCandidates.panels)) var panelID: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "focus-panel", helpNames: [])
}

struct ListPanesCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list-panes", helpNames: [])
}

struct ListPaneSurfacesCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("pane"), completion: paneCompletion) var paneID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list-pane-surfaces", helpNames: [])
}

struct ListPanelsCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list-panels", helpNames: [])
}

struct DragSurfaceToSplitCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("panel"), completion: .custom(CompletionCandidates.panels)) var panelID: String?
    @Argument(completion: .list(["left", "right", "up", "down"])) var direction: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Option(name: .customLong("focus")) var focus: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "drag-surface-to-split", helpNames: [])
}

struct SurfaceCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Option(name: .customLong("cwd"), completion: .directory) var cwd: String?
    @Option(name: .customLong("name")) var name: String?
    @Option(name: .customLong("kind")) var kind: String?
    @Option(name: [.customLong("checkpoint"), .customLong("checkpoint-id")]) var checkpoint: String?
    @Option(name: .customLong("source")) var source: String?
    @Option(name: .customLong("shell")) var shell: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "surface", helpNames: [])
}

struct SurfaceHealthCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "surface-health", helpNames: [])
}

struct SurfaceResumeCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Option(name: .customLong("cwd"), completion: .directory) var cwd: String?
    @Option(name: .customLong("name")) var name: String?
    @Option(name: .customLong("kind")) var kind: String?
    @Option(name: [.customLong("checkpoint"), .customLong("checkpoint-id")]) var checkpoint: String?
    @Option(name: .customLong("source")) var source: String?
    @Option(name: .customLong("shell")) var shell: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "surface-resume", helpNames: [])
}

struct DetachTabCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("tab"), completion: .custom(CompletionCandidates.tabs)) var tab: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Option(name: .customLong("title")) var title: String?
    @Option(name: .customLong("focus")) var focus: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "detach-tab", helpNames: [])
}

struct TabActionCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("action")) var action: String?
    @Option(name: .customLong("tab"), completion: .custom(CompletionCandidates.tabs)) var tab: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Option(name: .customLong("title")) var title: String?
    @Option(name: .customLong("url")) var url: String?
    @Option(name: .customLong("focus")) var focus: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "tab-action", helpNames: [])
}

struct RenameTabCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("tab"), completion: .custom(CompletionCandidates.tabs)) var tab: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Option(name: .customLong("title")) var title: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "rename-tab", helpNames: [])
}

struct LastPaneCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "last-pane", helpNames: [])
}

struct RefreshSurfacesCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "refresh-surfaces", helpNames: [])
}

struct DebugTerminalsCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "debug-terminals", helpNames: [])
}

struct SidebarStateCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "sidebar-state", helpNames: [])
}
