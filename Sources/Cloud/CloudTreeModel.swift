import Foundation

// The Cloud tree: what the right sidebar shows and what `cmux vm tree --json` prints.
// One shape for people and agents — machine → cmux-tui workspaces → terminals, plus the
// Mac-side synthetic Desktop and Ports nodes (cmux-tui has no VNC or port concept).
// Pure values: rows below list boundaries receive these, never a store.

enum CloudTreeLinkState: String, Codable, Sendable {
    case connected
    case connecting
    case asleep
    case unavailable
    case error
}

enum CloudTreeTerminalLifecycle: String, Codable, Sendable {
    case launching
    case running
    case exited
}

struct CloudTreeTerminal: Codable, Sendable, Equatable, Identifiable {
    /// cmux-tui public id (`term_…`).
    var id: String
    var title: String
    var cwd: String?
    var lifecycle: CloudTreeTerminalLifecycle
    var agentState: String?
    var agentSource: String?
    /// The local surface currently showing this terminal, when one is open.
    var openSurfaceID: String?

    enum CodingKeys: String, CodingKey {
        case id, title, cwd, lifecycle
        case agentState = "agent_state"
        case agentSource = "agent_source"
        case openSurfaceID = "open_surface_id"
    }
}

struct CloudTreeWorkspace: Codable, Sendable, Equatable, Identifiable {
    /// cmux-tui public id (`ws_…`).
    var id: String
    var name: String
    var focused: Bool
    var terminals: [CloudTreeTerminal]
}

struct CloudTreePort: Codable, Sendable, Equatable, Identifiable {
    var id: Int { port }
    var port: Int
    var label: String?
}

struct CloudTreeMachine: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var status: String
    var image: String
    var desktop: Bool
    var memoryMb: Int?
    var diskMb: Int?
    var linkState: CloudTreeLinkState
    var linkError: String?
    var workspaces: [CloudTreeWorkspace]
    var ports: [CloudTreePort]

    enum CodingKeys: String, CodingKey {
        case id, status, image, desktop, workspaces, ports
        case memoryMb = "memory_mb"
        case diskMb = "disk_mb"
        case linkState = "link_state"
        case linkError = "link_error"
    }

    var isAwake: Bool { status == "running" }
}

struct CloudTreeSnapshot: Codable, Sendable, Equatable {
    var machines: [CloudTreeMachine]
    static let empty = CloudTreeSnapshot(machines: [])
}

/// Where a tree node opens locally. Mirrors the socket params of `vm.terminal_open`.
enum CloudTreePlacement: String, Codable, Sendable {
    case split
    case tab
    case pane
}

/// A node that can be dragged out of the tree into the main view. Names a daemon-side
/// resource, not a VM, so the same payload can later serve ssh boxes and local sessions.
enum CloudTreeDragItem: Codable, Sendable, Equatable {
    case terminal(machineID: String, terminalID: String, title: String)
    case desktop(machineID: String)
    case port(machineID: String, port: Int)
}

/// The app-side service the sidebar and the `vm.*` socket methods share. One mutation path:
/// the CLI (`cmux vm open/tree/agent`) and the sidebar both call these.
@MainActor
protocol CloudTreeServicing: AnyObject {
    /// Current snapshot; `refresh` forces the machine list and every awake link to re-sync.
    func tree(machineID: String?, refresh: Bool) async throws -> CloudTreeSnapshot
    /// Opens (or focuses an already-open pane showing) a terminal of a machine's cmux-tui session.
    func openTerminal(machineID: String, terminalID: String, workspaceID: String?, placement: CloudTreePlacement?, focus: Bool) async throws -> CloudTreeOpenResult
    /// Creates a terminal in the machine's cmux-tui session (optionally running a command), optionally opening it locally.
    func newTerminal(machineID: String, workspaceID: String?, command: [String]?, cwd: String?, name: String?, open: Bool) async throws -> CloudTreeNewTerminalResult
    func openDesktop(machineID: String, workspaceID: String?, focus: Bool) async throws -> CloudTreeOpenURLResult
    func openPort(machineID: String, port: Int, workspaceID: String?) async throws -> CloudTreeOpenURLResult
    /// The headless cmux-tui link's local mux socket for a machine (ensures the link exists).
    func linkSocket(machineID: String) async throws -> CloudTreeLinkSocket
}

struct CloudTreeOpenResult: Codable, Sendable, Equatable {
    var surfaceID: String
    var workspaceID: String
    var reused: Bool
    enum CodingKeys: String, CodingKey {
        case surfaceID = "surface_id"
        case workspaceID = "workspace_id"
        case reused
    }
}

struct CloudTreeNewTerminalResult: Codable, Sendable, Equatable {
    var terminalID: String
    var workspaceID: String
    var surfaceID: String?
    enum CodingKeys: String, CodingKey {
        case terminalID = "terminal_id"
        case workspaceID = "workspace_id"
        case surfaceID = "surface_id"
    }
}

struct CloudTreeOpenURLResult: Codable, Sendable, Equatable {
    var surfaceID: String
    var url: String
    enum CodingKeys: String, CodingKey {
        case surfaceID = "surface_id"
        case url
    }
}

struct CloudTreeLinkSocket: Codable, Sendable, Equatable {
    var socketPath: String
    var session: String
    enum CodingKeys: String, CodingKey {
        case socketPath = "socket_path"
        case session
    }
}
