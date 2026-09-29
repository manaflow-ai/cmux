import Foundation

/// Fields shared by new-tab / split / new-pane / new-pane-right.
///
/// `cwd` and `env` (`terminal-env-v1`) reach `new-tab` and `split` only;
/// `new-pane` and `new-pane-right` ignore both. `argv`, `command`, and `name`
/// are accepted by `create-terminal` only; these four commands ignore them.
public struct SpawnOptions: Sendable, Hashable {
    public var cwd: String?
    public var size: CellSize?
    public var argv: [String]?
    public var command: String?
    public var name: String?
    /// Extra environment for the new terminal's child only. The daemon
    /// stores it with the creation receipt on disk, so never pass secrets;
    /// nil lets `DaemonConnection` send `TerminalEnvironment`'s allowlist.
    public var env: [String: String]?

    public init(cwd: String? = nil, size: CellSize? = nil, argv: [String]? = nil, command: String? = nil, name: String? = nil,
                env: [String: String]? = nil) {
        self.cwd = cwd
        self.size = size
        self.argv = argv
        self.command = command
        self.name = name
        self.env = env
    }

    enum CodingKeys: String, CodingKey { case cwd, cols, rows, argv, command, name, env }
    func encode(to encoder: any Encoder, includeCwd: Bool = true) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if includeCwd { try c.encodeIfPresent(cwd, forKey: .cwd) }
        try c.encodeIfPresent(size?.cols, forKey: .cols)
        try c.encodeIfPresent(size?.rows, forKey: .rows)
        try c.encodeIfPresent(argv, forKey: .argv)
        try c.encodeIfPresent(command, forKey: .command)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(env, forKey: .env)
    }
}

public struct NewTabRequest: DaemonRequest {
    public typealias Response = SurfaceCreated
    public static let command = "new-tab"
    public var pane: PaneID?
    public var options: SpawnOptions
    public init(pane: PaneID?, options: SpawnOptions = SpawnOptions()) {
        self.pane = pane
        self.options = options
    }
    enum CodingKeys: String, CodingKey { case pane }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(pane, forKey: .pane)
        try options.encode(to: encoder)
    }
}

public struct NewScreenRequest: DaemonRequest {
    public typealias Response = SurfaceCreated
    public static let command = "new-screen"
    public var workspace: WorkspaceHandle?
    public var size: CellSize?
    public init(workspace: WorkspaceHandle?, size: CellSize? = nil) {
        self.workspace = workspace
        self.size = size
    }
    enum CodingKeys: String, CodingKey { case workspace, cols, rows }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(workspace, forKey: .workspace)
        try c.encodeIfPresent(size?.cols, forKey: .cols)
        try c.encodeIfPresent(size?.rows, forKey: .rows)
    }
}
