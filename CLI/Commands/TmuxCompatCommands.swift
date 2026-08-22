import ArgumentParser
import Foundation

struct CapturePaneCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Flag(name: .customLong("scrollback")) var scrollback = false
    @Option(name: .customLong("lines")) var lines: Int?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "capture-pane", helpNames: [])
}

struct ResizePaneCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("pane"), completion: paneCompletion) var paneID: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Flag(name: .customShort("L")) var left = false
    @Flag(name: .customShort("R")) var right = false
    @Flag(name: .customShort("U")) var up = false
    @Flag(name: .customShort("D")) var down = false
    @Option(name: .customLong("amount")) var amount: Int?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "resize-pane", helpNames: [])
}

struct PipePaneCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Option(name: .customLong("command")) var command: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "pipe-pane", helpNames: [])
}

struct WaitForCommand: SharedLegacyFacadeCommand {
    @Flag(name: [.customShort("S"), .customLong("signal")]) var signal = false
    @Argument var name: String?
    @Option(name: .customLong("timeout")) var timeout: Double?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "wait-for", helpNames: [])
}

struct SwapPaneCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("pane"), completion: paneCompletion) var paneID: String?
    @Option(name: .customLong("target-pane"), completion: paneCompletion) var targetPaneID: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Option(name: .customLong("focus")) var focus: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "swap-pane", helpNames: [])
}

struct BreakPaneCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("pane"), completion: paneCompletion) var paneID: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Option(name: .customLong("focus")) var focus: String?
    @Flag(name: .customLong("no-focus")) var noFocus = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "break-pane", helpNames: [])
}

struct JoinPaneCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("target-pane"), completion: paneCompletion) var targetPaneID: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("pane"), completion: paneCompletion) var paneID: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Option(name: .customLong("focus")) var focus: String?
    @Flag(name: .customLong("no-focus")) var noFocus = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "join-pane", helpNames: [])
}

struct ClearHistoryCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "clear-history", helpNames: [])
}

struct SetHookCommand: SharedLegacyFacadeCommand {
    @Flag(name: .customLong("list")) var list = false
    @Option(name: .customLong("unset")) var unset: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "set-hook", helpNames: [])
}

private protocol TmuxCompatUnsupportedCommand: SharedLegacyFacadeCommand {
    static var commandName: String { get }
    var arguments: [String] { get set }
}

extension TmuxCompatUnsupportedCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(commandName: commandName, helpNames: [])
    }
}

struct PopupCommand: TmuxCompatUnsupportedCommand {
    static let commandName = "popup"
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
}
struct BindKeyCommand: TmuxCompatUnsupportedCommand {
    static let commandName = "bind-key"
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
}
struct UnbindKeyCommand: TmuxCompatUnsupportedCommand {
    static let commandName = "unbind-key"
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
}
struct CopyModeCommand: TmuxCompatUnsupportedCommand {
    static let commandName = "copy-mode"
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
}

struct SetBufferCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("name")) var name: String?
    @Argument(parsing: .allUnrecognized) var text: [String] = []
    static let configuration = CommandConfiguration(commandName: "set-buffer", helpNames: [])
}

struct ListBuffersCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list-buffers", helpNames: [])
}

struct PasteBufferCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("name")) var name: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "paste-buffer", helpNames: [])
}

struct RespawnPaneCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Option(name: .customLong("command")) var command: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "respawn-pane", helpNames: [])
}

struct DisplayMessageCommand: SharedLegacyFacadeCommand {
    @Flag(name: [.customShort("p"), .customLong("print")]) var printOnly = false
    @Argument(parsing: .allUnrecognized) var text: [String] = []
    static let configuration = CommandConfiguration(commandName: "display-message", helpNames: [])
}

struct ReadScreenCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Flag(name: .customLong("scrollback")) var scrollback = false
    @Option(name: .customLong("lines")) var lines: Int?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "read-screen", helpNames: [])
}

struct SendCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Argument(parsing: .allUnrecognized) var text: [String] = []
    static let configuration = CommandConfiguration(commandName: "send", helpNames: [])
}

struct SendKeyCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Argument(parsing: .allUnrecognized) var key: [String] = []
    static let configuration = CommandConfiguration(commandName: "send-key", helpNames: [])
}

struct SendPanelCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("panel"), completion: .custom(CompletionCandidates.panels)) var panelID: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Argument(parsing: .allUnrecognized) var text: [String] = []
    static let configuration = CommandConfiguration(commandName: "send-panel", helpNames: [])
}

struct SendKeyPanelCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("panel"), completion: .custom(CompletionCandidates.panels)) var panelID: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Argument(parsing: .allUnrecognized) var key: [String] = []
    static let configuration = CommandConfiguration(commandName: "send-key-panel", helpNames: [])
}

/// Hidden shim entrypoint that preserves tmux's unparsed command line.
struct TmuxCompatCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "__tmux-compat", shouldDisplay: false, helpNames: [])
}
