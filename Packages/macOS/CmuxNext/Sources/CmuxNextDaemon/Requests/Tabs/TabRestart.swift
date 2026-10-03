import Foundation

/// Restarts a dead terminal tab in place (`restart-tab`, `tab-restart-v1`):
/// the daemon starts a new shell in the dead terminal's last directory and
/// points the same tab at it (id, placement, name, pin and group stay). A
/// replayed `idempotencyKey` returns the first result.
public struct RestartTabRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var surface: SurfaceID
        public var terminal: String
        public var replacedTerminal: String
        public var replayed: Bool

        enum CodingKeys: String, CodingKey {
            case surface, terminal, replayed
            case replacedTerminal = "replaced_terminal"
        }
    }

    public static let command = "restart-tab"
    public var surface: SurfaceID
    public var idempotencyKey: String?
    public var cwd: String?
    public var env: [String: String]?
    /// Restart only a host loss; the daemon rejects a process that ended on
    /// its own (`tab-restart-not-lost`). The automatic restart sets it.
    public var onlyLost: Bool

    public init(surface: SurfaceID, idempotencyKey: String?, cwd: String? = nil, env: [String: String]? = nil,
                onlyLost: Bool = false) {
        self.surface = surface
        self.idempotencyKey = idempotencyKey
        self.cwd = cwd
        self.env = env
        self.onlyLost = onlyLost
    }
}

extension RestartTabRequest {
    /// The key every client derives for restarting `tab` from the terminal
    /// it shows now: a manual Restart, the automatic restart, the kept-layout
    /// relaunch and other clients send it, so one dead terminal's tab
    /// restarts once (the daemon replays the key). The tab is part of it
    /// because the daemon's replay record names the tab.
    public static func idempotencyKey(tab: TabSnapshot) -> String {
        let surface = "surface:\(tab.surface.rawValue)"
        let terminal = tab.terminalResourceID?.rawValue ?? tab.terminalID.map { "terminal:\($0.rawValue)" } ?? surface
        return "tab-restart:\(tab.tabResourceID?.rawValue ?? surface):\(terminal)"
    }
}

extension DaemonConnection {
    /// Needs `tab-restart-v1`. `fallbackCwd` is used only when the daemon
    /// knows no directory for the dead terminal.
    @discardableResult
    public func restartTab(_ surface: SurfaceID, idempotencyKey: String?, fallbackCwd: String? = nil,
                           onlyLost: Bool = false) async throws -> RestartTabRequest.Response {
        guard identity?.supports(DaemonCapabilities.shared.tabRestart) == true else {
            throw DaemonError.missingCapabilities([DaemonCapabilities.shared.tabRestart])
        }
        let env = await terminalEnvironment(nil)
        return try await request(RestartTabRequest(surface: surface, idempotencyKey: idempotencyKey, cwd: fallbackCwd,
                                                   env: env, onlyLost: onlyLost))
    }
}
