import Foundation

/// Compatibility name kept for the first Harbor panel implementation. The
/// tree model uses `HarborHostRef`, while older pane-drop call sites still
/// refer to a source. A type alias keeps both paths on one identity type.
typealias HarborSource = HarborHostRef

/// Where a Harbor item lives: this Mac, or a user-added SSH destination.
enum HarborHostRef: Hashable, Codable, Sendable {
    case local
    case ssh(destination: String)

    var displayName: String {
        switch self {
        case .local:
            return String(localized: "harbor.source.local", defaultValue: "This Mac")
        case .ssh(let destination):
            return destination
        }
    }

    var isLocal: Bool {
        if case .local = self { return true }
        return false
    }

    var key: String {
        switch self {
        case .local: return "local"
        case .ssh(let destination): return "ssh:\(destination)"
        }
    }
}

/// A terminal-session tool Harbor can discover.
enum HarborTool: String, CaseIterable, Codable, Sendable {
    case cmuxTui = "cmux-tui"
    case tmux
    case zellij
    case screen
    case zmx
    case herdr

    /// Tool names are product names, not translatable UI copy.
    var displayName: String { rawValue }

    var symbolName: String {
        switch self {
        case .cmuxTui: return "square.grid.2x2"
        case .tmux: return "rectangle.split.3x1"
        case .zellij: return "rectangle.split.2x2"
        case .screen: return "display"
        case .zmx: return "bolt.horizontal"
        case .herdr: return "point.3.connected.trianglepath.dotted"
        }
    }
}

enum HarborSessionState: String, Codable, Sendable {
    case attached
    case detached
    case exited
    case running
    case stopped
    case unknown

    var label: String {
        switch self {
        case .attached: return String(localized: "harbor.state.attached", defaultValue: "attached")
        case .detached: return String(localized: "harbor.state.detached", defaultValue: "detached")
        case .exited: return String(localized: "harbor.state.exited", defaultValue: "exited")
        case .running: return String(localized: "harbor.state.running", defaultValue: "running")
        case .stopped: return String(localized: "harbor.state.stopped", defaultValue: "stopped")
        case .unknown: return String(localized: "harbor.state.unknown", defaultValue: "unknown")
        }
    }
}

/// Lifecycle state reported by Herdr's agent detector. This mirrors the
/// public state vocabulary, but does not copy Herdr implementation code.
/// See https://github.com/herdrdev/herdr and the Apache-2.0 licensed CLI API.
enum HarborAgentState: String, Codable, Sendable {
    case working
    case blocked
    case idle
    case done
    case unknown

    var label: String {
        switch self {
        case .working: return String(localized: "harbor.agent.state.working", defaultValue: "working")
        case .blocked: return String(localized: "harbor.agent.state.blocked", defaultValue: "blocked")
        case .idle: return String(localized: "harbor.agent.state.idle", defaultValue: "idle")
        case .done: return String(localized: "harbor.agent.state.done", defaultValue: "done")
        case .unknown: return String(localized: "harbor.agent.state.unknown", defaultValue: "unknown")
        }
    }

    /// Lower values receive earlier placement in Harbor. Attention states are
    /// visible before background or unclassified agents.
    var attentionRank: Int {
        switch self {
        case .blocked: return 0
        case .working: return 1
        case .done: return 2
        case .idle: return 3
        case .unknown: return 4
        }
    }
}

/// Agent metadata exposed by a host's integration. `kind` stays a string so
/// new Herdr integrations (or a different multiplexer) appear immediately.
struct HarborAgentInfo: Hashable, Codable, Sendable {
    let kind: String
    let name: String?
    let state: HarborAgentState
    let message: String?
    let priority: Int?

    init(
        kind: String,
        name: String? = nil,
        state: HarborAgentState,
        message: String? = nil,
        priority: Int? = nil
    ) {
        self.kind = kind
        self.name = name
        self.state = state
        self.message = message
        self.priority = priority
    }

    var displayName: String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedName.isEmpty ? kind : "\(kind): \(trimmedName)"
    }

    var sortRank: Int {
        priority ?? state.attentionRank
    }
}

/// One inner terminal Harbor can attach to through the tool's control API,
/// with no rendered client TUI: a tmux pane over `-CC` control mode, or a
/// cmux-tui daemon terminal over `attach --pipe-io`.
enum HarborLeaf: Hashable, Sendable {
    /// A tmux pane (`%paneID`) inside `sessionName` on `host`; `windowID` is
    /// the `@N` id used for per-window size claims.
    case tmuxPane(host: HarborHostRef, sessionName: String, windowID: Int, paneID: Int)
    /// A Herdr pane addressed by the public pane id. This compatibility case
    /// is used only when an older probe has no terminal id; the current
    /// attach path cannot guarantee a pane-level target without that id.
    case herdrPane(host: HarborHostRef, sessionName: String, paneID: String)
    /// A Herdr terminal with the terminal id returned by `pane list`. Herdr's
    /// attach command accepts this id, while the pane id remains useful for
    /// display and workspace grouping.
    case herdrTerminal(host: HarborHostRef, sessionName: String, paneID: String, terminalID: String)
    /// A cmux-tui daemon terminal. Local daemons are addressed by socket
    /// path; remote ones by session name, reached over ssh stdio.
    case tuiTerminal(host: HarborHostRef, sessionName: String, socketPath: String?, terminalID: String)

    var host: HarborHostRef {
        switch self {
        case .tmuxPane(let host, _, _, _): return host
        case .herdrPane(let host, _, _): return host
        case .herdrTerminal(let host, _, _, _): return host
        case .tuiTerminal(let host, _, _, _): return host
        }
    }
}

/// Compatibility value for the session-level Harbor panel and pane-drop API.
/// New tree rows use `HarborTerminalInfo` and `HarborDragItem`; this value is
/// retained until all callers move to terminal-level drops.
struct HarborSession: Identifiable, Hashable, Codable, Sendable {
    let source: HarborSource
    let tool: HarborTool
    let name: String
    let state: HarborSessionState
    let detail: String

    var id: String { "\(source.key)/\(tool.rawValue)/\(name)" }

    static func isCmuxInfrastructureSession(name: String, ownSessionName: String?) -> Bool {
        HarborSessionInfo.isCmuxInfrastructureSession(name: name, ownSessionName: ownSessionName)
    }
}

/// What one dragged (or clicked) Harbor row means.
enum HarborDragItem: Hashable, Sendable {
    /// Direct API attach of one inner terminal (manual IO, no client TUI).
    case leaf(HarborLeaf, title: String)
    /// Whole-session attach that runs the tool's own client inside a
    /// terminal. Offered only where no per-terminal API exists and the
    /// client adds no chrome (zmx), or explicitly from a context menu.
    case sessionTUI(host: HarborHostRef, tool: HarborTool, sessionName: String, state: HarborSessionState)
    /// Compatibility item used by the original session-only panel while it is
    /// being migrated to terminal rows.
    case legacySession(HarborSession)

    var title: String {
        switch self {
        case .leaf(_, let title): return title
        case .sessionTUI(_, _, let sessionName, _): return sessionName
        case .legacySession(let session): return session.name
        }
    }
}

// MARK: - Discovered tree

struct HarborTerminalInfo: Hashable, Sendable {
    let leaf: HarborLeaf?
    /// Stable full identity used for outline reconciliation. `shortID` is
    /// display text and may be truncated for long daemon ids.
    let stableID: String
    let shortID: String
    let title: String
    let isActive: Bool
    let cwd: String?
    let agent: HarborAgentInfo?

    init(
        leaf: HarborLeaf?,
        shortID: String,
        title: String,
        isActive: Bool,
        cwd: String? = nil,
        agent: HarborAgentInfo? = nil,
        stableID: String? = nil
    ) {
        self.leaf = leaf
        self.stableID = stableID ?? shortID
        self.shortID = shortID
        self.title = title
        self.isActive = isActive
        self.cwd = cwd
        self.agent = agent
    }

    var attentionRank: Int { agent?.sortRank ?? HarborAgentState.unknown.attentionRank }
}

struct HarborWindowInfo: Hashable, Sendable {
    let id: String
    let label: String
    let terminals: [HarborTerminalInfo]
}

struct HarborSessionInfo: Hashable, Sendable {
    let tool: HarborTool
    let name: String
    let state: HarborSessionState
    let detail: String
    /// Window/workspace groups. Empty for tools that expose only sessions.
    let windows: [HarborWindowInfo]
    /// Terminals attached directly to the session (no window grouping).
    let looseTerminals: [HarborTerminalInfo]

    /// Session names cmux itself owns; listing them invites recursion.
    static func isCmuxInfrastructureSession(name: String, ownSessionName: String?) -> Bool {
        if let ownSessionName, name == ownSessionName { return true }
        return name.hasPrefix("cmux-browser-")
    }
}

struct HarborHostSnapshot: Sendable {
    enum Status: Equatable, Sendable {
        case loading
        case loaded
        case unreachable(String)
    }

    let host: HarborHostRef
    var status: Status
    var sessions: [HarborSessionInfo]
}

// MARK: - TUI-fallback attach commands (session-level only)

/// Builds the attach command a session-level TUI attach runs in a plain
/// terminal. Used for zmx (a chromeless single-terminal client) and for the
/// explicit "Attach as TUI" context-menu action on other tools.
enum HarborAttachCommand {
    static func shellCommand(for session: HarborSession) -> String {
        shellCommand(host: session.source, tool: session.tool, name: session.name, state: session.state)
    }

    static func terminalName(for session: HarborSession) -> String {
        "harbor:\(session.tool.rawValue):\(session.name)"
    }

    static func terminalName(for item: HarborDragItem) -> String {
        switch item {
        case .legacySession(let session): return terminalName(for: session)
        case .sessionTUI(_, let tool, let sessionName, _):
            return "harbor:\(tool.rawValue):\(sessionName)"
        case .leaf(let leaf, let title):
            let host = leaf.host.key.replacingOccurrences(of: "/", with: "-")
            return "harbor:\(host):\(title)"
        }
    }

    static func shellCommand(for item: HarborDragItem) -> String {
        switch item {
        case .legacySession(let session):
            return shellCommand(for: session)
        case .sessionTUI(let host, let tool, let sessionName, let state):
            return shellCommand(host: host, tool: tool, name: sessionName, state: state)
        case .leaf(let leaf, _):
            return leafShellCommand(leaf)
        }
    }

    static func shellCommand(host: HarborHostRef, tool: HarborTool, name: String, state: HarborSessionState) -> String {
        let local = localAttachCommand(tool: tool, name: name, state: state)
        switch host {
        case .local:
            return local
        case .ssh(let destination):
            // Remote hosts rarely have xterm-ghostty terminfo; downgrade
            // TERM for the remote command only.
            return "exec ssh -t \(shellQuote(destination)) -- \(shellQuote("TERM=xterm-256color " + local))"
        }
    }

    private static func localAttachCommand(tool: HarborTool, name: String, state: HarborSessionState) -> String {
        let quoted = shellQuote(name)
        switch tool {
        case .tmux:
            return "exec tmux attach-session -t \(quoted)"
        case .zellij:
            return "exec zellij attach \(quoted)"
        case .screen:
            // -r resumes a detached session; -x joins one attached elsewhere.
            return state == .attached ? "exec screen -x \(quoted)" : "exec screen -r \(quoted)"
        case .zmx:
            return "exec zmx attach \(quoted)"
        case .herdr:
            return "exec herdr session attach \(quoted)"
        case .cmuxTui:
            return "exec cmux-tui attach --session \(quoted)"
        }
    }

    private static func leafShellCommand(_ leaf: HarborLeaf) -> String {
        switch leaf {
        case .tmuxPane(let host, let sessionName, let windowID, let paneID):
            // Attaching to a pane-qualified target makes the terminal open on
            // the dragged pane instead of only selecting the session.
            let target = "\(sessionName):@\(windowID).%\(paneID)"
            return shellCommand(host: host, tool: .tmux, name: target, state: .detached)
        case .herdrPane(let host, let sessionName, let paneID):
            // Older Herdr probes exposed only a pane id. Keep the case for
            // compatibility, but use the same command shape as the terminal
            // case because Herdr's attach command consumes terminal ids.
            let local = "exec herdr --session \(shellQuote(sessionName)) terminal attach \(shellQuote(paneID))"
            switch host {
            case .local: return local
            case .ssh(let destination):
                return "exec ssh -t \(shellQuote(destination)) -- \(shellQuote("TERM=xterm-256color " + local))"
            }
        case .herdrTerminal(let host, let sessionName, _, let terminalID):
            let local = "exec herdr --session \(shellQuote(sessionName)) terminal attach \(shellQuote(terminalID))"
            switch host {
            case .local: return local
            case .ssh(let destination):
                return "exec ssh -t \(shellQuote(destination)) -- \(shellQuote("TERM=xterm-256color " + local))"
            }
        case .tuiTerminal(let host, let sessionName, let socketPath, let terminalID):
            let local = socketPath.map { "exec cmux-tui --socket \(shellQuote($0)) attach --terminal \(shellQuote(terminalID))" }
                ?? "exec cmux-tui attach --session \(shellQuote(sessionName)) --terminal \(shellQuote(terminalID))"
            switch host {
            case .local:
                return local
            case .ssh(let destination):
                return "exec ssh -t \(shellQuote(destination)) -- \(shellQuote("TERM=xterm-256color " + local))"
            }
        }
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
