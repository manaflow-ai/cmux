import Foundation

/// `{surface}` plus the terminal identity newer servers add, and the pane that holds the new surface
/// (`pane`: cmux-tui names it for `split`, `new-pane`, `new-pane-right` and `new-screen`), so a caller works on
/// the new pane without reading the whole tree (`list-workspaces`, about 3.7 KB per workspace).
public struct SurfaceCreated: Decodable, Sendable, Equatable {
    public var surface: SurfaceID
    public var terminalID: TerminalID?
    public var terminalIncarnation: TerminalIncarnation?
    /// The pane that holds `surface`; nil from a daemon that does not name it.
    public var pane: PaneID?

    init(surface: SurfaceID, terminalID: TerminalID? = nil, terminalIncarnation: TerminalIncarnation? = nil, pane: PaneID? = nil) {
        self.surface = surface
        self.terminalID = terminalID
        self.terminalIncarnation = terminalIncarnation
        self.pane = pane
    }

    enum CodingKeys: String, CodingKey {
        case surface, pane
        case terminalID = "terminal_id"
        case terminalIncarnation = "terminal_incarnation"
    }
}

public struct CreateTerminalResult: Decodable, Sendable, Equatable {
    public var surface: SurfaceID?
    public var terminalID: TerminalID
    public var terminalIncarnation: TerminalIncarnation?
    public var pane: PaneID?
    public var screen: ScreenID?
    public var workspace: WorkspaceHandle?
    public var key: WorkspaceKey
    public var lifecycle: String
    public var alreadyExited: Bool?
    public var terminalRevision: UInt64?
    public var replayed: Bool

    enum CodingKeys: String, CodingKey {
        case surface, pane, screen, workspace, key, lifecycle, replayed
        case terminalID = "terminal_id"
        case terminalIncarnation = "terminal_incarnation"
        case alreadyExited = "already_exited"
        case terminalRevision = "terminal_revision"
    }
}

/// Spawns a terminal inside a workspace (a new screen/pane when it is empty).
public struct CreateTerminalRequest: TerminalSpawningRequest {
    public typealias Response = CreateTerminalResult
    public static let command = "create-terminal"
    public var workspace: WorkspaceRef
    public var argv: [String]?
    public var command: String?
    public var cwd: String?
    public var name: String?
    public var size: CellSize?
    public var terminalID: TerminalID?
    /// Extra environment for the child only (`terminal-env-v1`); stored on
    /// disk with the receipt, so never pass secrets.
    public var env: [String: String]?
    /// `true` keeps the terminal after its last tab closes (`terminal-reap-v1`).
    public var keep: Bool?
    public var mutation: MutationIdentity?
    /// Arguments for the terminal's shell (`terminal-shell-args-v1`), set by
    /// `DaemonConnection` from `env`; never with `argv` or `command`.
    public var shellArgs: [String]?

    public init(workspace: WorkspaceRef, argv: [String]? = nil, command: String? = nil, cwd: String? = nil,
                name: String? = nil, size: CellSize? = nil, terminalID: TerminalID? = nil, env: [String: String]? = nil,
                keep: Bool? = nil, mutation: MutationIdentity?) {
        self.workspace = workspace
        self.argv = argv
        self.command = command
        self.cwd = cwd
        self.name = name
        self.size = size
        self.terminalID = terminalID
        self.env = env
        self.keep = keep
        self.mutation = mutation
    }

    enum CodingKeys: String, CodingKey {
        case argv, command, cwd, name, cols, rows, terminalID, env, keep
        case shellArgs = "shell_args"
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(argv, forKey: .argv)
        try c.encodeIfPresent(command, forKey: .command)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(size?.cols, forKey: .cols)
        try c.encodeIfPresent(size?.rows, forKey: .rows)
        try c.encodeIfPresent(terminalID, forKey: .terminalID)
        try c.encodeIfPresent(env, forKey: .env)
        try c.encodeIfPresent(keep, forKey: .keep)
        try c.encodeIfPresent(shellArgs, forKey: .shellArgs)
        try WorkspaceRefFields(ref: workspace).encode(to: encoder)
        try MutationFields(identity: mutation).encode(to: encoder)
    }
}
