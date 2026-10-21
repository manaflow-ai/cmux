import Foundation

/// The running acpmux daemon's build against this app's bundled acpmux, for Update cmux
/// Components… (plans/cmux-next/server-updates-DESIGN.md section 7).
public nonisolated struct AcpmuxBuildCheck: Sendable, Equatable {
    /// The daemon's `_acpmux/status` build, nil when it does not report one.
    public var running: String?
    /// The bundled acpmux's build (`acpmux --version`), nil when unknown.
    public var bundled: String?
    /// The daemon runs its agents under agent hosts: a handoff keeps them.
    public var agentHosts: Bool

    public init(running: String?, bundled: String?, agentHosts: Bool) {
        self.running = running
        self.bundled = bundled
        self.agentHosts = agentHosts
    }
}

extension AcpmuxEnvironment {
    /// The running daemon's build and the bundled one. Nil when no daemon answers on this
    /// environment's socket, or the one that answers serves another acpmux home (another app's
    /// or tag's). Never starts, stops or hands off a daemon.
    public nonisolated func buildCheck() async -> AcpmuxBuildCheck? {
        guard let status = try? await AcpmuxStatusClient.status(socketPath: socketPath), status.serves(home: home) else {
            return nil
        }
        return AcpmuxBuildCheck(running: status.build, bundled: await AcpmuxVersionHandoff.bundledBuild(self),
                                agentHosts: status.agentHosts)
    }
}
