import Foundation

/// What `CmuxTUIRemote.probe(on:)` found on a host.
public struct CmuxTUIProbe: Sendable, Equatable {
    /// `uname -s`, e.g. `Linux` or `Darwin`.
    public var os: String
    /// `uname -m`, e.g. `x86_64`, `aarch64`, `arm64`.
    public var arch: String
    /// The binary path as the remote shell resolved it (`~` expanded).
    public var binaryPath: String
    /// `nil` when no executable exists at ``binaryPath``.
    public var installed: CmuxTUIInstalledBinary?

    /// The npm platform package that carries a binary for this host
    /// (`cmux-tui-linux-x64`, ...), or `nil` for an unsupported platform.
    public var npmPlatformPackage: String? {
        let system: String
        switch os.lowercased() {
        case "linux": system = "linux"
        case "darwin": system = "darwin"
        default: return nil
        }
        let cpu: String
        switch arch.lowercased() {
        case "x86_64", "amd64": cpu = "x64"
        case "aarch64", "arm64": cpu = "arm64"
        default: return nil
        }
        return "cmux-tui-\(system)-\(cpu)"
    }
}

/// Identity reported by an installed `cmux-tui` (`remote-probe --json`, or
/// `--version` on binaries without that verb).
public struct CmuxTUIInstalledBinary: Sendable, Equatable {
    /// Crate version, e.g. `0.1.0`.
    public var version: String?
    /// npm/PyPI release version, e.g. `0.13.4`. Compare this for upgrades.
    public var distributionVersion: String?
    public var buildIdentity: String?
    /// Remote-daemon protocol (not the control protocol negotiated by `identify`).
    public var remoteProtocol: Int?
    /// Unparsed probe output, for diagnostics.
    public var rawProbe: String
}

/// Server identity negotiated by the `identify` handshake.
public struct CmuxTUIServerInfo: Sendable, Equatable {
    public var app: String
    public var version: String
    public var protocolVersion: Int
    public var capabilities: Set<String>
    public var session: String
    public var pid: Int
    /// Daemon boot UUID; changes when the owner restarts.
    public var generation: String?
    public var buildCommit: String?
}

/// A workspace and the PTY terminals and browser tabs placed in it, each
/// flattened across screens and panes in layout order.
public struct CmuxTUIWorkspace: Sendable, Equatable, Identifiable {
    /// Numeric id; valid for this daemon generation only.
    public var id: Int
    /// Stable workspace UUID (survives daemon restarts). Prefer it for storage.
    public var key: String?
    /// Resource API v2 id (`ws_...`).
    public var resourceID: String?
    public var name: String
    public var active: Bool
    public var terminals: [CmuxTUITerminal]
    /// Browser tabs. Present only when the server runs a `cmux-browser`
    /// provider (cmux-tui never launches Chrome itself).
    public var browsers: [CmuxTUIBrowserTab] = []
    /// Screens in order, each with its panes in layout order. Terminals and
    /// browsers reference them through `screen` and `pane`.
    public var screens: [CmuxTUIScreen] = []

    public init(
        id: Int,
        key: String?,
        resourceID: String? = nil,
        name: String,
        active: Bool = false,
        terminals: [CmuxTUITerminal],
        browsers: [CmuxTUIBrowserTab] = [],
        screens: [CmuxTUIScreen] = []
    ) {
        self.id = id
        self.key = key
        self.resourceID = resourceID
        self.name = name
        self.active = active
        self.terminals = terminals
        self.browsers = browsers
        self.screens = screens
    }
}

/// One screen (a full-window layout of panes) of a workspace.
public struct CmuxTUIScreen: Sendable, Equatable, Identifiable {
    /// Numeric id; valid for this daemon generation only.
    public var id: Int
    /// User-set name; `nil` when unnamed.
    public var name: String?
    /// The pane `new-tab` targets by default.
    public var activePane: Int?
    public var panes: [CmuxTUIPane]

    public init(id: Int, name: String? = nil, activePane: Int? = nil, panes: [CmuxTUIPane]) {
        self.id = id
        self.name = name
        self.activePane = activePane
        self.panes = panes
    }
}

/// One pane (a split region holding tabs) of a screen.
public struct CmuxTUIPane: Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String?

    public init(id: Int, name: String? = nil) {
        self.id = id
        self.name = name
    }
}

/// One PTY tab view of a session-owned terminal.
public struct CmuxTUITerminal: Sendable, Equatable, Identifiable {
    public var id: Int { surface }
    /// Numeric surface id used by attach, send, and resize.
    public var surface: Int
    public var pane: Int
    public var screen: Int
    /// Resource API v2 terminal id (`term_...`), used by `closeTerminal`.
    public var resourceID: String?
    public var terminalID: String?
    public var name: String?
    /// Latest OSC title reported by the program.
    public var title: String
    public var cols: Int?
    public var rows: Int?
    public var dead: Bool

    public init(
        surface: Int,
        pane: Int,
        screen: Int,
        resourceID: String? = nil,
        terminalID: String? = nil,
        name: String? = nil,
        title: String = "",
        cols: Int? = nil,
        rows: Int? = nil,
        dead: Bool = false
    ) {
        self.surface = surface
        self.pane = pane
        self.screen = screen
        self.resourceID = resourceID
        self.terminalID = terminalID
        self.name = name
        self.title = title
        self.cols = cols
        self.rows = rows
        self.dead = dead
    }
}

/// Result of creating a terminal.
public struct CmuxTUICreatedTerminal: Sendable, Equatable {
    /// `nil` when the child exited before creation returned.
    public var surface: Int?
    public var terminalID: String
    public var workspace: Int?
    public var workspaceKey: String
    /// `launching`, `adopting`, `running`, `exited`, or `tombstoned`.
    public var lifecycle: String
    public var alreadyExited: Bool
}

/// Result of creating a workspace.
public struct CmuxTUICreatedWorkspace: Sendable, Equatable {
    public var workspace: Int
    public var key: String
    /// The initial terminal, when one was requested.
    public var terminal: CmuxTUICreatedTerminal?
}

/// Effective colors and cursor metadata for an attached terminal. The VT
/// replay does not carry DECSCUSR, so apply ``cursorStyle``/``cursorBlink``
/// after replaying. Colors are `#rrggbb` or `nil` (use the local theme).
public struct CmuxTUITerminalColors: Sendable, Equatable {
    public var foreground: String?
    public var background: String?
    public var cursor: String?
    public var selectionBackground: String?
    public var selectionForeground: String?
    /// Sparse OSC 4 overrides; absent indexes keep the local palette.
    public var palette: [Int: String]
    /// `block`, `underline`, `bar`, or `nil`.
    public var cursorStyle: String?
    public var cursorBlink: Bool?
}

/// One frame of a byte-mode attach stream, in server order.
public enum CmuxTUIAttachEvent: Sendable, Equatable {
    /// Initial VT replay. Feed it to a fresh terminal of `cols` x `rows`.
    case vtState(Data, cols: Int, rows: Int)
    /// Live PTY bytes that follow the replay with no gap or duplication.
    case output(Data)
    /// The canonical grid changed. Reset the local terminal to `cols` x `rows`,
    /// apply `replay`, then continue with later output.
    case resized(cols: Int, rows: Int, replay: Data)
    /// Colors or cursor metadata to apply (after `vtState`/`resized`, or live).
    case colors(CmuxTUITerminalColors)
    /// The server ended the stream: the surface exited or disappeared.
    case exited
    /// The transport closed. Not proof the terminal is gone; reconnect and
    /// re-list before reattaching.
    case disconnected
}

/// Session-wide notifications from ``CmuxTUIControl/subscribe()``.
public enum CmuxTUIControlEvent: Sendable, Equatable {
    /// Workspaces, panes, or tabs changed; call `listWorkspaces()`.
    case treeChanged
    case titleChanged(surface: Int, title: String)
    case surfaceExited(surface: Int)
    case surfaceResized(surface: Int, cols: Int, rows: Int)
    case bell(surface: Int)
    /// The last workspace closed.
    case empty
    /// The subscriber fell behind and the server ended the subscription.
    /// Subscribe again and re-list.
    case overflow
    case daemonShutdown
    case disconnected
}

/// Outcome of an attached-view resize.
public enum CmuxTUIResizeOutcome: String, Sendable, Equatable {
    /// The canonical grid changed; a `resized` frame follows.
    case applied
    /// Recorded as a hint; another view owns geometry.
    case passive
    /// The attach lease is no longer current.
    case superseded
}

public enum CmuxTUIError: Error, Equatable, Sendable {
    /// The session name is not a valid single path component.
    case invalidSessionName(String)
    /// No executable at the configured path.
    case binaryMissing(String)
    /// `server ensure` or `relay` exited before the handshake completed.
    case serverStartFailed(exitStatus: Int?, message: String)
    /// The server speaks an older control protocol.
    case unsupportedProtocol(Int)
    /// The server lacks a capability this client requires.
    case missingCapability(String)
    /// The server returned `ok:false`.
    case commandFailed(command: String, message: String, code: String?)
    case malformedResponse(String)
    /// This connection already has a stream for the surface.
    case alreadyAttached(Int)
    /// The control connection closed.
    case closed
}
