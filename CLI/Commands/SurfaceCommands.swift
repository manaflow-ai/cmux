import ArgumentParser
import Foundation

/// Routes pane and surface facade declarations through the established CLI implementation.
private protocol LegacySurfaceCommand: ParsableCommand {}

extension LegacySurfaceCommand {
    func run() throws {
        try GlobalOptions().makeCLI().run()
    }
}

private protocol SurfaceTargetCommand: LegacySurfaceCommand {}

extension SurfaceTargetCommand {
    static var surface: CompletionKind { .custom(CompletionCandidates.surfaces) }
    static var pane: CompletionKind { .custom(CompletionCandidates.panes) }
    static var workspace: CompletionKind { .custom(CompletionCandidates.workspaces) }
    static var window: CompletionKind { .custom(CompletionCandidates.windows) }
}

struct NewPaneCommand: SurfaceTargetCommand {
    @Option(name: .customLong("type"), completion: .list(["terminal", "browser", "simulator"])) var type: String?
    @Option(name: .customLong("direction"), completion: .list(["left", "right", "up", "down"])) var direction: String?
    @Option(name: .customLong("placement"), completion: .list(["workspace", "dock"])) var placement: String?
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Option(name: .customLong("url")) var url: String?
    @Option(name: .customLong("profile")) var profile: String?
    @Option(name: .customLong("focus")) var focus: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "new-pane", helpNames: [])
}

struct NewSplitCommand: SurfaceTargetCommand {
    @Argument(completion: .list(["left", "right", "up", "down"])) var direction: String?
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("panel"), completion: .custom(CompletionCandidates.panels)) var panelID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Option(name: .customLong("focus")) var focus: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "new-split", helpNames: [])
}

struct NewSurfaceCommand: SurfaceTargetCommand {
    @Option(name: .customLong("type"), completion: .list(["terminal", "browser", "simulator", "agent-session"])) var type: String?
    @Option(name: .customLong("pane"), completion: pane) var paneID: String?
    @Option(name: .customLong("placement"), completion: .list(["workspace", "dock"])) var placement: String?
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Option(name: .customLong("url")) var url: String?
    @Option(name: [.customLong("provider"), .customLong("provider-id")]) var provider: String?
    @Option(name: [.customLong("renderer"), .customLong("renderer-kind")]) var renderer: String?
    @Option(name: [.customLong("working-directory"), .customLong("cwd")], completion: .directory) var workingDirectory: String?
    @Option(name: .customLong("focus")) var focus: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "new-surface", helpNames: [])
}

struct CloseSurfaceCommand: SurfaceTargetCommand {
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("panel"), completion: .custom(CompletionCandidates.panels)) var panelID: String?
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "close-surface", helpNames: [])
}

struct MoveSurfaceCommand: SurfaceTargetCommand {
    @Argument(completion: surface) var target: String?
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("pane"), completion: pane) var paneID: String?
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Option(name: [.customLong("before"), .customLong("before-surface")], completion: surface) var before: String?
    @Option(name: [.customLong("after"), .customLong("after-surface")], completion: surface) var after: String?
    @Option(name: .customLong("index")) var index: Int?
    @Option(name: .customLong("focus")) var focus: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "move-surface", helpNames: [])
}

struct SplitOffCommand: SurfaceTargetCommand {
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("panel"), completion: .custom(CompletionCandidates.panels)) var panelID: String?
    @Argument(completion: .list(["left", "right", "up", "down"])) var direction: String?
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Option(name: .customLong("focus")) var focus: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "split-off", helpNames: [])
}

struct ReorderSurfaceCommand: SurfaceTargetCommand {
    @Argument(completion: surface) var target: String?
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Option(name: [.customLong("before"), .customLong("before-surface")], completion: surface) var before: String?
    @Option(name: [.customLong("after"), .customLong("after-surface")], completion: surface) var after: String?
    @Option(name: .customLong("index")) var index: Int?
    @Option(name: .customLong("focus")) var focus: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "reorder-surface", helpNames: [])
}

struct FocusPaneCommand: SurfaceTargetCommand {
    @Argument(completion: pane) var target: String?
    @Option(name: .customLong("pane"), completion: pane) var paneID: String?
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "focus-pane", helpNames: [])
}

struct FocusPanelCommand: SurfaceTargetCommand {
    @Option(name: .customLong("panel"), completion: .custom(CompletionCandidates.panels)) var panelID: String?
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "focus-panel", helpNames: [])
}

struct ListPanesCommand: SurfaceTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list-panes", helpNames: [])
}

struct ListPaneSurfacesCommand: SurfaceTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("pane"), completion: pane) var paneID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list-pane-surfaces", helpNames: [])
}

struct ListPanelsCommand: SurfaceTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list-panels", helpNames: [])
}

struct DragSurfaceToSplitCommand: SurfaceTargetCommand {
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("panel"), completion: .custom(CompletionCandidates.panels)) var panelID: String?
    @Argument(completion: .list(["left", "right", "up", "down"])) var direction: String?
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Option(name: .customLong("focus")) var focus: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "drag-surface-to-split", helpNames: [])
}

struct SurfaceCommand: SurfaceTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Option(name: .customLong("cwd"), completion: .directory) var cwd: String?
    @Option(name: .customLong("name")) var name: String?
    @Option(name: .customLong("kind")) var kind: String?
    @Option(name: [.customLong("checkpoint"), .customLong("checkpoint-id")]) var checkpoint: String?
    @Option(name: .customLong("source")) var source: String?
    @Option(name: .customLong("shell")) var shell: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "surface", helpNames: [])
}

struct SurfaceHealthCommand: SurfaceTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "surface-health", helpNames: [])
}

struct SurfaceResumeCommand: SurfaceTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Option(name: .customLong("cwd"), completion: .directory) var cwd: String?
    @Option(name: .customLong("name")) var name: String?
    @Option(name: .customLong("kind")) var kind: String?
    @Option(name: [.customLong("checkpoint"), .customLong("checkpoint-id")]) var checkpoint: String?
    @Option(name: .customLong("source")) var source: String?
    @Option(name: .customLong("shell")) var shell: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "surface-resume", helpNames: [])
}

struct DetachTabCommand: SurfaceTargetCommand {
    @Option(name: .customLong("tab"), completion: .custom(CompletionCandidates.tabs)) var tab: String?
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Option(name: .customLong("title")) var title: String?
    @Option(name: .customLong("focus")) var focus: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "detach-tab", helpNames: [])
}

struct TabActionCommand: SurfaceTargetCommand {
    @Option(name: .customLong("action")) var action: String?
    @Option(name: .customLong("tab"), completion: .custom(CompletionCandidates.tabs)) var tab: String?
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Option(name: .customLong("title")) var title: String?
    @Option(name: .customLong("url")) var url: String?
    @Option(name: .customLong("focus")) var focus: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "tab-action", helpNames: [])
}

struct RenameTabCommand: SurfaceTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("tab"), completion: .custom(CompletionCandidates.tabs)) var tab: String?
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Option(name: .customLong("title")) var title: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "rename-tab", helpNames: [])
}

struct LastPaneCommand: SurfaceTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "last-pane", helpNames: [])
}

struct RefreshSurfacesCommand: LegacySurfaceCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "refresh-surfaces", helpNames: [])
}

struct DebugTerminalsCommand: LegacySurfaceCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "debug-terminals", helpNames: [])
}

struct SidebarStateCommand: SurfaceTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "sidebar-state", helpNames: [])
}
