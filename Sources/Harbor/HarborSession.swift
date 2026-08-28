import Foundation

/// A terminal-session tool Harbor can discover and attach to.
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

/// Where a session lives: this Mac, or a user-added SSH destination
/// (`user@host`, or an alias from `~/.ssh/config`).
enum HarborSource: Hashable, Codable, Sendable {
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
}

/// One attachable session discovered by the probe.
struct HarborSession: Identifiable, Hashable, Sendable {
    let source: HarborSource
    let tool: HarborTool
    let name: String
    let state: HarborSessionState
    let detail: String

    var id: String {
        let sourceKey: String
        switch source {
        case .local: sourceKey = "local"
        case .ssh(let destination): sourceKey = "ssh:\(destination)"
        }
        return "\(sourceKey)/\(tool.rawValue)/\(name)"
    }

    /// Session names cmux itself owns: this app instance's bridge daemon and
    /// the embedded-browser helper daemons. Listing them invites recursive
    /// attaches, so discovery drops them.
    static func isCmuxInfrastructureSession(name: String, ownSessionName: String?) -> Bool {
        if let ownSessionName, name == ownSessionName { return true }
        return name.hasPrefix("cmux-browser-")
    }
}

/// Parses `tool<TAB>name<TAB>state<TAB>detail` lines emitted by
/// `HarborSessionProbe.script`. Unknown tools and malformed lines are
/// skipped so one bad stanza never hides the rest of a host's sessions.
enum HarborProbeOutputParser {
    static func sessions(fromProbeOutput output: String, source: HarborSource, ownSessionName: String? = nil) -> [HarborSession] {
        var seen = Set<String>()
        var sessions: [HarborSession] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let tool = HarborTool(rawValue: String(fields[0])) else { continue }
            let name = String(fields[1])
            guard !name.isEmpty else { continue }
            if tool == .cmuxTui,
               HarborSession.isCmuxInfrastructureSession(name: name, ownSessionName: ownSessionName) {
                continue
            }
            let state = HarborSessionState(rawValue: String(fields[2])) ?? .unknown
            let session = HarborSession(
                source: source,
                tool: tool,
                name: name,
                state: state,
                detail: fields.count > 3 ? String(fields[3]) : ""
            )
            // The probe can report one session from two socket directories.
            guard seen.insert(session.id).inserted else { continue }
            sessions.append(session)
        }
        return sessions
    }
}

/// Builds the attach command a dropped Harbor row runs. The command executes
/// under the daemon's default login shell (`workspace run shell …`) so tool
/// binaries resolve through the user's PATH, and under `ssh -t` for remote
/// sessions so the remote side allocates a PTY.
enum HarborAttachCommand {
    static func shellCommand(for session: HarborSession) -> String {
        let local = localAttachCommand(tool: session.tool, name: session.name, state: session.state)
        switch session.source {
        case .local:
            return local
        case .ssh(let destination):
            // The daemon PTY exports TERM=xterm-ghostty, which most remote
            // hosts have no terminfo entry for (screen refuses to start,
            // tmux garbles). Downgrade TERM for the remote command only;
            // Ghostty renders xterm-256color output fine.
            return "exec ssh -t \(shellQuote(destination)) -- \(shellQuote("TERM=xterm-256color " + local))"
        }
    }

    /// A short daemon-side terminal name so `terminal list` stays readable.
    static func terminalName(for session: HarborSession) -> String {
        "harbor:\(session.tool.rawValue):\(session.name)"
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

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
