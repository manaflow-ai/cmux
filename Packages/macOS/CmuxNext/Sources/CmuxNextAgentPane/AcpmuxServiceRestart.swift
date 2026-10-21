import Foundation
import os

/// Which acpmux build runs for one acpmux home and which build this app bundles, for Restart
/// Background Services (cmux issue 23089).
public nonisolated struct AcpmuxServiceBuilds: Sendable, Equatable {
    /// The running daemon's build (`_acpmux/status` `build`); nil when no daemon of this home runs.
    public var running: String?
    /// The bundled acpmux's build (`acpmux --version`); nil when it could not be read.
    public var bundled: String?
    /// The running daemon keeps its agents across a restart (`agentHosts`). True when none runs.
    public var keepsAgents: Bool

    public init(running: String?, bundled: String?, keepsAgents: Bool) {
        self.running = running
        self.bundled = bundled
        self.keepsAgents = keepsAgents
    }
}

/// Restart Background Services (cmux issue 23089): one acpmux home's daemon is stopped by its own
/// `_acpmux/shutdown` without `endAgents`, as an update handoff stops it
/// (``AcpmuxVersionHandoff``): every agent runs on under its agent host and the next daemon, of
/// the bundled build, adopts it. Its router of the old build is replaced by that daemon too
/// unless a kept agent still uses it (acpmux `daemon/router_owner/users.rs`). A daemon without
/// agent hosts would end its agents, so it is never stopped here.
public nonisolated struct AcpmuxServiceRestart: Sendable {
    enum Failure: Error, CustomStringConvertible {
        /// The daemon runs no agent hosts: a restart would end its agents.
        case wouldEndAgents
        /// The daemon refused or did not answer `_acpmux/shutdown`.
        case refused(String)
        /// The daemon did not exit after its shutdown.
        case stillRunning(Int32)

        var description: String {
            switch self {
            case .wouldEndAgents: "its agents would end (it runs no agent hosts)"
            case .refused(let reason): "it refused to stop: \(reason)"
            case .stillRunning(let pid): "it (pid \(pid)) did not stop"
            }
        }
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")

    let environment: AcpmuxEnvironment

    public init(environment: AcpmuxEnvironment) {
        self.environment = environment
    }

    /// The running and bundled builds of this home.
    @concurrent public func builds() async -> AcpmuxServiceBuilds {
        let bundled = await AcpmuxVersionHandoff.bundledBuild(environment)
        guard let status = try? await AcpmuxStatusClient.status(socketPath: environment.socketPath),
              status.serves(home: environment.home) else {
            return AcpmuxServiceBuilds(running: nil, bundled: bundled, keepsAgents: true)
        }
        return AcpmuxServiceBuilds(running: status.build, bundled: bundled, keepsAgents: status.agentHosts)
    }

    /// Stops this home's daemon, keeping its agents, and waits for its exit (the next daemon needs
    /// its lock). Returns the stopped pid; nil when no daemon of this home runs.
    @concurrent func stop() async throws -> Int32? {
        guard let status = try? await AcpmuxStatusClient.status(socketPath: environment.socketPath),
              status.serves(home: environment.home), let pid = status.pid else { return nil }
        guard status.agentHosts else { throw Failure.wouldEndAgents }
        do {
            try await AcpmuxStatusClient.shutdown(socketPath: environment.socketPath, home: environment.home)
        } catch {
            throw Failure.refused(String(describing: error))
        }
        guard await AgentPaneProcessExit(pid: pid).event(within: .seconds(15)) else { throw Failure.stillRunning(pid) }
        Self.logger.info("acpmux \(pid) of \(environment.home.path, privacy: .public) stopped for a restart; its agents keep running")
        return pid
    }
}

extension AcpmuxHost {
    /// The running and bundled acpmux builds of this host's home; nil when acpmux is not found.
    public func serviceBuilds() async -> AcpmuxServiceBuilds? {
        if environment == nil { environment = resolveEnvironment() }
        guard let environment else { return nil }
        return await AcpmuxServiceRestart(environment: environment).builds()
    }

    /// Restart Background Services: stops this host's daemon, keeping its agents, and starts the
    /// bundled build with this host's settings, as the first chat after an update does. Only a host
    /// that starts its daemon (the app's own home); the Chief home's daemon restarts through its
    /// host (``ChiefAcpmuxHeal``).
    public func restartDaemon() async throws {
        guard startsDaemons else { throw AgentPaneHostError.chiefStopped }
        _ = try await endpoint(startsDaemon: true, restart: true)
        if let restartFailure { throw restartFailure }
    }
}
