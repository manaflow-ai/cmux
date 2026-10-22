import Darwin
public import Foundation
import os
import CmuxNextCompat
import CmuxNextWakeups

/// The process that holds this app's acpmux socket when the app may not use its daemon: the
/// binary it runs and the team that signed it (nil: no team, as a cargo build or a DEV build is).
/// The pane's refusal names it, so a person sees which acpmux is in the way (2026-10-22: a daemon
/// on NIGHTLY's shared `~/.acpmux` was refused as "not signed by this app's team" with no name,
/// and Retry only asked again), and offers to restart acpmux from this app's own binary
/// (``takeOver(environment:)``). Naming it is not a trust decision: the peer check stays as it is.
public nonisolated struct AcpmuxSocketOwner: Equatable, Sendable {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")

    /// The resolved path of the binary the daemon runs.
    public var path: String
    /// Its signing team ID, nil when it has none.
    public var team: String?

    public init(path: String, team: String?) {
        self.path = path
        self.team = team
    }

    /// Who holds `socketPath` now, read from a connection's own peer facts. Nil when nothing
    /// answers or the peer runs as another user: the app never offers to stop another user's daemon.
    static func read(socketPath: String) -> AcpmuxSocketOwner? {
        guard let peer = AcpmuxServerPeer.socketPeer(socketPath: socketPath), peer.uid == getuid() else { return nil }
        return AcpmuxSocketOwner(path: peer.executablePath, team: peer.signingTeam)
    }

    /// Daemons (by pid) a person already asked this process to replace: a second ask while the
    /// first one runs waits on nothing and fails, so two clicks never stop two daemons.
    private static let stopping = Mutex<Set<Int32>>([])

    /// A person asked to restart acpmux from this app's own binary (the pane's Restart acpmux):
    /// stops the daemon on `environment`'s socket the way an update hands one off, so its agents
    /// detach and the next daemon adopts them, and its sessions stay on disk. The caller's next
    /// handshake starts this app's daemon. Only a daemon of this user that serves this app's home
    /// and does not run this app's own acpmux is stopped; a launchd job that runs it is booted out
    /// first so KeepAlive does not start it again. True when that daemon exited.
    static func takeOver(environment: AcpmuxEnvironment) async -> Bool {
        guard let peer = AcpmuxServerPeer.socketPeer(socketPath: environment.socketPath), peer.uid == getuid(),
              !peer.runs(environment.executable) else { return false }
        let pid = peer.pid
        guard stopping.withLock({ $0.insert(pid).inserted }) else { return false }
        defer { _ = stopping.withLock { $0.remove(pid) } }
        logger.info("acpmux \(pid) at \(peer.executablePath, privacy: .public) is not this app's; a person asked to restart it from \(environment.executable.path, privacy: .public)")
        if await AcpmuxStrayDaemon.bootOutLaunchdJob(runningPID: pid),
           await AgentPaneProcessExit(pid: pid).event(within: .seconds(15)) {
            return true
        }
        do {
            try await AcpmuxStatusClient.shutdown(socketPath: environment.socketPath, home: environment.home)
        } catch {
            logger.error("acpmux restart request failed: \(String(describing: error), privacy: .public)")
            return false
        }
        // The old daemon holds its lock until it exits; the new one needs it.
        return await AgentPaneProcessExit(pid: pid).event(within: .seconds(15))
    }
}
