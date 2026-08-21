import ArgumentParser
import Foundation

/// Routes tmux compatibility facade declarations through the established CLI implementation.
private protocol LegacyTmuxCompatCommand: ParsableCommand {}

extension LegacyTmuxCompatCommand {
    func run() throws {
        try GlobalOptions().makeCLI().run()
    }
}

private protocol TmuxCompatTargetCommand: LegacyTmuxCompatCommand {}

extension TmuxCompatTargetCommand {
    static var workspace: CompletionKind { .custom(CompletionCandidates.workspaces) }
    static var surface: CompletionKind { .custom(CompletionCandidates.surfaces) }
    static var pane: CompletionKind { .custom(CompletionCandidates.panes) }
    static var window: CompletionKind { .custom(CompletionCandidates.windows) }
}

struct CapturePaneCommand: TmuxCompatTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Flag(name: .customLong("scrollback")) var scrollback = false
    @Option(name: .customLong("lines")) var lines: Int?
    static let configuration = CommandConfiguration(commandName: "capture-pane", helpNames: [])
}

struct ResizePaneCommand: TmuxCompatTargetCommand {
    @Option(name: .customLong("pane"), completion: pane) var paneID: String?
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Flag(name: .customShort("L")) var left = false
    @Flag(name: .customShort("R")) var right = false
    @Flag(name: .customShort("U")) var up = false
    @Flag(name: .customShort("D")) var down = false
    @Option(name: .customLong("amount")) var amount: Int?
    static let configuration = CommandConfiguration(commandName: "resize-pane", helpNames: [])
}

struct PipePaneCommand: TmuxCompatTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Option(name: .customLong("command")) var command: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "pipe-pane", helpNames: [])
}

struct WaitForCommand: LegacyTmuxCompatCommand {
    @Flag(name: [.customShort("S"), .customLong("signal")]) var signal = false
    @Argument var name: String?
    @Option(name: .customLong("timeout")) var timeout: Double?
    static let configuration = CommandConfiguration(commandName: "wait-for", helpNames: [])
}

struct SwapPaneCommand: TmuxCompatTargetCommand {
    @Option(name: .customLong("pane"), completion: pane) var paneID: String?
    @Option(name: .customLong("target-pane"), completion: pane) var targetPaneID: String?
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Option(name: .customLong("focus")) var focus: String?
    static let configuration = CommandConfiguration(commandName: "swap-pane", helpNames: [])
}

struct BreakPaneCommand: TmuxCompatTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("pane"), completion: pane) var paneID: String?
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Option(name: .customLong("focus")) var focus: String?
    @Flag(name: .customLong("no-focus")) var noFocus = false
    static let configuration = CommandConfiguration(commandName: "break-pane", helpNames: [])
}

struct JoinPaneCommand: TmuxCompatTargetCommand {
    @Option(name: .customLong("target-pane"), completion: pane) var targetPaneID: String?
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("pane"), completion: pane) var paneID: String?
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Option(name: .customLong("focus")) var focus: String?
    @Flag(name: .customLong("no-focus")) var noFocus = false
    static let configuration = CommandConfiguration(commandName: "join-pane", helpNames: [])
}

struct ClearHistoryCommand: TmuxCompatTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    static let configuration = CommandConfiguration(commandName: "clear-history", helpNames: [])
}

struct SetHookCommand: LegacyTmuxCompatCommand {
    @Flag(name: .customLong("list")) var list = false
    @Option(name: .customLong("unset")) var unset: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "set-hook", helpNames: [])
}

private protocol TmuxCompatUnsupportedCommand: LegacyTmuxCompatCommand {
    static var commandName: String { get }
}

extension TmuxCompatUnsupportedCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(commandName: commandName, helpNames: [])
    }
}

struct PopupCommand: TmuxCompatUnsupportedCommand { static let commandName = "popup" }
struct BindKeyCommand: TmuxCompatUnsupportedCommand { static let commandName = "bind-key" }
struct UnbindKeyCommand: TmuxCompatUnsupportedCommand { static let commandName = "unbind-key" }
struct CopyModeCommand: TmuxCompatUnsupportedCommand { static let commandName = "copy-mode" }

struct SetBufferCommand: LegacyTmuxCompatCommand {
    @Option(name: .customLong("name")) var name: String?
    @Argument(parsing: .allUnrecognized) var text: [String] = []
    static let configuration = CommandConfiguration(commandName: "set-buffer", helpNames: [])
}

struct ListBuffersCommand: LegacyTmuxCompatCommand {
    static let configuration = CommandConfiguration(commandName: "list-buffers", helpNames: [])
}

struct PasteBufferCommand: TmuxCompatTargetCommand {
    @Option(name: .customLong("name")) var name: String?
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    static let configuration = CommandConfiguration(commandName: "paste-buffer", helpNames: [])
}

struct RespawnPaneCommand: TmuxCompatTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Option(name: .customLong("command")) var command: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "respawn-pane", helpNames: [])
}

struct DisplayMessageCommand: LegacyTmuxCompatCommand {
    @Flag(name: [.customShort("p"), .customLong("print")]) var printOnly = false
    @Argument(parsing: .allUnrecognized) var text: [String] = []
    static let configuration = CommandConfiguration(commandName: "display-message", helpNames: [])
}

struct ReadScreenCommand: TmuxCompatTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Flag(name: .customLong("scrollback")) var scrollback = false
    @Option(name: .customLong("lines")) var lines: Int?
    static let configuration = CommandConfiguration(commandName: "read-screen", helpNames: [])
}

struct SendCommand: TmuxCompatTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Argument(parsing: .allUnrecognized) var text: [String] = []
    static let configuration = CommandConfiguration(commandName: "send", helpNames: [])
}

struct SendKeyCommand: TmuxCompatTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surface) var surfaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Argument(parsing: .allUnrecognized) var key: [String] = []
    static let configuration = CommandConfiguration(commandName: "send-key", helpNames: [])
}

struct SendPanelCommand: TmuxCompatTargetCommand {
    @Option(name: .customLong("panel"), completion: surface) var panelID: String?
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Argument(parsing: .allUnrecognized) var text: [String] = []
    static let configuration = CommandConfiguration(commandName: "send-panel", helpNames: [])
}

struct SendKeyPanelCommand: TmuxCompatTargetCommand {
    @Option(name: .customLong("panel"), completion: surface) var panelID: String?
    @Option(name: .customLong("workspace"), completion: workspace) var workspaceID: String?
    @Option(name: .customLong("window"), completion: window) var windowID: String?
    @Argument(parsing: .allUnrecognized) var key: [String] = []
    static let configuration = CommandConfiguration(commandName: "send-key-panel", helpNames: [])
}

/// Hidden shim entrypoint that preserves tmux's unparsed command line.
struct TmuxCompatCommand: LegacyTmuxCompatCommand {
    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "__tmux-compat", shouldDisplay: false, helpNames: [])
}
