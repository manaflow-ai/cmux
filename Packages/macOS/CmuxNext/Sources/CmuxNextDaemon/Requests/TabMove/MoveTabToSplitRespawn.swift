import Foundation

/// The new tab a split spawns in the source pane when the dragged tab was
/// its only one (`tab-split-respawn-v1`): the same kind, fresh (a new
/// terminal in the dragged terminal's directory, or a new tab page), never
/// a copy of the dragged tab's state.
public enum SplitRespawn: Sendable, Hashable, Encodable {
    /// A new terminal, spawned like `new-tab`: `cwd`, the placement `env`,
    /// `terminalID` and `shellArgs` reach the daemon (`DaemonConnection`
    /// fills in the last three, as for every terminal it creates).
    case terminal(SpawnOptions)
    /// A new frontend browser tab on `url` (the New Tab page) with the
    /// dragged tab's engine and browser profile.
    case browser(url: String, engine: BrowserEngine, profileID: String?)

    private enum CodingKeys: String, CodingKey {
        case kind, cwd, env, url, engine
        case terminalID = "terminal_id", shellArgs = "shell_args", profileID = "profile_id"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .terminal(let options):
            try container.encode("terminal", forKey: .kind)
            try container.encodeIfPresent(options.cwd, forKey: .cwd)
            try container.encodeIfPresent(options.env, forKey: .env)
            try container.encodeIfPresent(options.terminalID, forKey: .terminalID)
            try container.encodeIfPresent(options.shellArgs, forKey: .shellArgs)
        case .browser(let url, let engine, let profileID):
            try container.encode("browser", forKey: .kind)
            try container.encode(url, forKey: .url)
            try container.encode(engine, forKey: .engine)
            try container.encodeIfPresent(profileID, forKey: .profileID)
        }
    }
}

/// `move-tab-to-split` with `respawn`: one owner op that moves the tab into
/// a new pane beside its own pane and spawns `respawn` in the pane it left.
/// It can launch a terminal host, so it uses the spawn deadline.
public struct MoveTabToSplitRespawnRequest: TerminalSpawningRequest {
    public typealias Response = TabMoveResult
    public static let command = "move-tab-to-split"
    public static let requiredCapability: String? = DaemonCapabilities.shared.tabSplitRespawn
    public var surface: SurfaceID
    public var pane: PaneID
    public var edge: PaneEdge
    public var ratio: Double?
    public var respawn: SplitRespawn
    public var transaction: ClientTransactionID?
    public init(surface: SurfaceID, pane: PaneID, edge: PaneEdge, ratio: Double? = nil, respawn: SplitRespawn,
                transaction: ClientTransactionID? = nil) {
        self.surface = surface
        self.pane = pane
        self.edge = edge
        self.ratio = ratio
        self.respawn = respawn
        self.transaction = transaction
    }
}

extension MoveTabToSplitRespawnRequest {
    /// Sends this request on `connection`. A fresh terminal gets its own
    /// host id and placement environment, as from `new-tab`.
    @discardableResult
    public func send(on connection: DaemonConnection) async throws -> TabMoveResult {
        var request = self
        if case .terminal(let options) = respawn { request.respawn = .terminal(await connection.placed(options)) }
        return try await connection.request(request)
    }
}
