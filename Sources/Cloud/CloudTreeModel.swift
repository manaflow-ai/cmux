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

/// The side of a pane a split lands on; the same tokens `surface.split` takes.
enum CloudTreeSplitDirection: String, Codable, Sendable {
    case left
    case right
    case up
    case down
}

/// Exactly where a tree node opens: the pane it is dropped on, a surface in that
/// pane (what `surface.split` splits from), and the side, or a tab index for an
/// insert into the pane's tab strip. A drop carries the real Bonsplit destination
/// through this so a Cloud terminal lands where a Vault session or a file would.
/// Mirrors the optional `pane_id` / `surface_id` / `direction` / `tab_index`
/// socket params.
struct CloudTreeOpenTarget: Codable, Sendable, Equatable {
    var paneID: String?
    var surfaceID: String?
    var direction: CloudTreeSplitDirection?
    var tabIndex: Int?

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case surfaceID = "surface_id"
        case direction
        case tabIndex = "tab_index"
    }

    init(paneID: String? = nil, surfaceID: String? = nil, direction: CloudTreeSplitDirection? = nil, tabIndex: Int? = nil) {
        self.paneID = paneID
        self.surfaceID = surfaceID
        self.direction = direction
        self.tabIndex = tabIndex
    }

    /// A direction means a split; anything else adds a tab to the pane.
    var placement: CloudTreePlacement { direction == nil ? .tab : .split }

    /// Nothing to aim at: the service falls back to the workspace's focused pane.
    var isEmpty: Bool { paneID == nil && surfaceID == nil && direction == nil && tabIndex == nil }
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
    /// `target` pins the pane and side (a drop); nil opens relative to the workspace's focused pane.
    func openTerminal(machineID: String, terminalID: String, workspaceID: String?, placement: CloudTreePlacement?, focus: Bool, target: CloudTreeOpenTarget?) async throws -> CloudTreeOpenResult
    /// Creates a terminal in the machine's cmux-tui session (optionally running a command), optionally opening it locally.
    func newTerminal(machineID: String, workspaceID: String?, command: [String]?, cwd: String?, name: String?, open: Bool) async throws -> CloudTreeNewTerminalResult
    func openDesktop(machineID: String, workspaceID: String?, focus: Bool, target: CloudTreeOpenTarget?) async throws -> CloudTreeOpenURLResult
    func openPort(machineID: String, port: Int, workspaceID: String?, target: CloudTreeOpenTarget?) async throws -> CloudTreeOpenURLResult
    /// The headless cmux-tui link's local mux socket for a machine (ensures the link exists).
    func linkSocket(machineID: String) async throws -> CloudTreeLinkSocket
}

extension CloudTreeServicing {
    /// Opens relative to the workspace's focused pane (no drop target).
    func openTerminal(machineID: String, terminalID: String, workspaceID: String?, placement: CloudTreePlacement?, focus: Bool) async throws -> CloudTreeOpenResult {
        try await openTerminal(machineID: machineID, terminalID: terminalID, workspaceID: workspaceID, placement: placement, focus: focus, target: nil)
    }

    func openDesktop(machineID: String, workspaceID: String?, focus: Bool) async throws -> CloudTreeOpenURLResult {
        try await openDesktop(machineID: machineID, workspaceID: workspaceID, focus: focus, target: nil)
    }

    func openPort(machineID: String, port: Int, workspaceID: String?) async throws -> CloudTreeOpenURLResult {
        try await openPort(machineID: machineID, port: port, workspaceID: workspaceID, target: nil)
    }
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
