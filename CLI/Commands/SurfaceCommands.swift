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

/// `surface` is a namespace, not a leaf: `runSurfaceCommand` dispatches `ls`,
/// `open`, `new-terminal` into the surface catalog and `resume` into the restart
/// metadata commands, and rejects a bare `cmux surface`. Declaring it as a single
/// unrecognized-argument sink meant `cmux surface <TAB>` offered nothing and the
/// options below (which really belong to `resume set`) were offered everywhere.
///
/// See VMCommand's comment: no catch-all argument alongside `subcommands`, and
/// `defaultSubcommand` absorbs anything that doesn't name a declared one, so an
/// unknown verb still reaches the legacy parser's own diagnostic instead of
/// ArgumentParser's "Unexpected argument". `ls` matches the read-only default
/// `vm`, `auth`, and `remotes` already use.
struct SurfaceCommand: SharedLegacyFacadeCommand {
    static let configuration = CommandConfiguration(
        commandName: "surface",
        subcommands: [
            SurfaceListCommand.self,
            SurfaceOpenCommand.self,
            SurfaceNewTerminalCommand.self,
            SurfaceResumeGroupCommand.self,
        ],
        defaultSubcommand: SurfaceListCommand.self,
        helpNames: []
    )
}

struct SurfaceListCommand: SharedLegacyFacadeCommand {
    /// A machine id, or `local` for This Mac.
    @Argument(completion: vmCompletion) var machine: String?
    @Flag(name: .customLong("refresh")) var refresh = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(
        commandName: "ls",
        helpNames: [],
        aliases: ["list", "tree", "catalog"]
    )
}

struct SurfaceOpenCommand: SharedLegacyFacadeCommand {
    /// `<machine>/<kind>/<key>`, e.g. `local/terminal/<uuid>`. Not completable
    /// from a flat entity list: the catalog is the only source, and resolving it
    /// on Tab would need a `surface.catalog` round trip per keystroke.
    @Argument var resource: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("pane"), completion: paneCompletion) var paneID: String?
    // The four sides are mutually exclusive with each other and with --tab, and
    // the legacy runner enforces that (and that they need --pane) itself.
    @Flag(name: .customLong("left")) var left = false
    @Flag(name: .customLong("right")) var right = false
    @Flag(name: .customLong("up")) var up = false
    @Flag(name: .customLong("down")) var down = false
    @Flag(name: .customLong("tab")) var tab = false
    @Flag(name: .customLong("new")) var new = false
    @Option(name: .customLong("focus")) var focus: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(
        commandName: "open",
        helpNames: [],
        aliases: ["project"]
    )
}

struct SurfaceNewTerminalCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("machine"), completion: vmCompletion) var machine: String?
    @Option(name: .customLong("cwd"), completion: .directory) var cwd: String?
    @Option(name: .customLong("name")) var name: String?
    @Option(name: .customLong("remote-workspace")) var remoteWorkspace: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Flag(name: .customLong("no-open")) var noOpen = false
    /// `-- <command...>` runs in the new terminal.
    @Argument(parsing: .captureForPassthrough) var command: [String] = []
    static let configuration = CommandConfiguration(
        commandName: "new-terminal",
        helpNames: [],
        aliases: ["new"]
    )
}

/// `surface resume`. Named apart from `SurfaceResumeCommand`, which declares the
/// top-level `surface-resume` alias of this same runner.
struct SurfaceResumeGroupCommand: SharedLegacyFacadeCommand {
    static let configuration = CommandConfiguration(
        commandName: "resume",
        subcommands: SurfaceResumeSubcommands.all,
        defaultSubcommand: SurfaceResumeShowCommand.self,
        helpNames: []
    )
}

/// The one list both `surface resume` and the `surface-resume` alias declare, so
/// the two spellings cannot drift apart.
enum SurfaceResumeSubcommands {
    static let all: [ParsableCommand.Type] = [
        SurfaceResumeShowCommand.self,
        SurfaceResumeSetCommand.self,
        SurfaceResumeClearCommand.self,
    ]
}

/// The selector every `surface resume` verb accepts.
struct SurfaceResumeTargetOptions: ParsableArguments {
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces))
    var workspaceID: String?
    @Option(name: .customLong("surface"), completion: .custom(CompletionCandidates.surfaces))
    var surfaceID: String?
    @Option(name: .customLong("window"), completion: .custom(CompletionCandidates.windows))
    var windowID: String?
}

struct SurfaceResumeShowCommand: SharedLegacyFacadeCommand {
    @OptionGroup var target: SurfaceResumeTargetOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "show", helpNames: [], aliases: ["get"])
}

struct SurfaceResumeSetCommand: SharedLegacyFacadeCommand {
    @OptionGroup var target: SurfaceResumeTargetOptions
    @Option(name: .customLong("name")) var name: String?
    @Option(name: .customLong("kind")) var kind: String?
    @Option(name: [.customLong("checkpoint"), .customLong("checkpoint-id")]) var checkpoint: String?
    @Option(name: .customLong("source")) var source: String?
    @Option(name: .customLong("cwd"), completion: .directory) var cwd: String?
    @Option(name: .customLong("shell")) var shell: String?
    /// `--shell <command>` or `-- <argv...>`; the runner rejects both together.
    @Argument(parsing: .captureForPassthrough) var command: [String] = []
    static let configuration = CommandConfiguration(commandName: "set", helpNames: [])
}

struct SurfaceResumeClearCommand: SharedLegacyFacadeCommand {
    @OptionGroup var target: SurfaceResumeTargetOptions
    @Option(name: [.customLong("checkpoint"), .customLong("checkpoint-id")]) var checkpoint: String?
    @Option(name: .customLong("source")) var source: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "clear", helpNames: [])
}

struct SurfaceHealthCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "surface-health", helpNames: [])
}

/// The top-level `surface-resume` spelling of `surface resume`; both reach
/// `validateSurfaceResumeCommandValueOptions` and the same runner, so both
/// declare the same subcommands.
struct SurfaceResumeCommand: SharedLegacyFacadeCommand {
    static let configuration = CommandConfiguration(
        commandName: "surface-resume",
        subcommands: SurfaceResumeSubcommands.all,
        defaultSubcommand: SurfaceResumeShowCommand.self,
        helpNames: []
    )
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
