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
    /// handshake starts this app's daemon. True when that daemon exited.
    ///
    /// Everything is decided and sent on ONE connection whose peer was read on that very
    /// descriptor, never on a fresh one (a daemon that took the socket between two connections is
    /// never stopped in another's name). It stops only a daemon that:
    /// - runs as this user and not from this app's own acpmux;
    /// - reports, on that connection, the peer's own pid, this app's home, and agent hosts (an
    ///   older daemon without them would end its agents, so it keeps running).
    /// A launchd job that runs that pid is booted out first so KeepAlive does not start it again;
    /// the lookup runs while the connection shows the process alive, so its pid is not reused.
    @concurrent static func takeOver(environment: AcpmuxEnvironment) async -> Bool {
        guard let descriptor = try? AcpmuxServerPeer.connect(environment.socketPath) else { return false }
        var open = true
        defer { if open { Darwin.close(descriptor) } }
        guard let peer = UnixSocketPeer(descriptor: descriptor), peer.uid == getuid(),
              !peer.runs(environment.executable) else { return false }
        let pid = peer.pid
        guard stopping.withLock({ $0.insert(pid).inserted }) else { return false }
        defer { _ = stopping.withLock { $0.remove(pid) } }
        let until = Date().addingTimeInterval(5)
        let status: AcpmuxStatus
        do {
            status = AcpmuxStatus(try request(id: 2, method: "_acpmux/status", on: descriptor, initialize: true, until: until))
        } catch {
            logger.error("acpmux restart: no status from \(pid): \(String(describing: error), privacy: .public)")
            return false
        }
        guard status.pid == pid, status.serves(home: environment.home) else {
            logger.error("acpmux restart refused: the socket's daemon reports pid \(status.pid ?? -1) home \(status.home ?? "?", privacy: .public), its peer is \(pid)")
            return false
        }
        guard status.agentHosts else {
            logger.error("acpmux \(pid) at \(peer.executablePath, privacy: .public) has no agent hosts; its agents would end, so it keeps running")
            return false
        }
        logger.info("acpmux \(pid) at \(peer.executablePath, privacy: .public) is not this app's; a person asked to restart it from \(environment.executable.path, privacy: .public)")
        if await AcpmuxStrayDaemon.bootOutLaunchdJob(runningPID: pid) {
            return await AgentPaneProcessExit(pid: pid).event(within: .seconds(15))
        }
        do {
            _ = try request(id: 3, method: "_acpmux/shutdown", on: descriptor, initialize: false, until: Date().addingTimeInterval(5))
        } catch AcpmuxServerPeer.Refusal.closed {
            // The daemon may close the connection as it stops, before its reply.
        } catch {
            logger.error("acpmux restart request failed: \(String(describing: error), privacy: .public)")
            return false
        }
        Darwin.close(descriptor)
        open = false
        // The old daemon holds its lock until it exits; the new one needs it.
        return await AgentPaneProcessExit(pid: pid).event(within: .seconds(15))
    }

    /// Sends `method` (after `initialize` when asked) on `descriptor` and returns the result of
    /// reply `id`; a JSON-RPC error throws ``AcpmuxRPCError``.
    private static func request(id: Int, method: String, on descriptor: Int32, initialize: Bool,
                                until: Date) throws -> [String: Any] {
        var payload = Data()
        if initialize {
            let hello: [String: Any] = [
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": ["protocolVersion": 1, "clientInfo": ["name": "cmux-next-restart", "version": "1"], "clientCapabilities": [:]],
            ]
            payload += try JSONSerialization.data(withJSONObject: hello) + Data([0x0A])
        }
        let call: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": [String: Any]()]
        payload += try JSONSerialization.data(withJSONObject: call) + Data([0x0A])
        try AcpmuxServerPeer.write(payload, to: descriptor, until: until)
        var buffer = Data()
        while true {  // wakeup-allow: each pass waits in poll(2) for socket data; EOF, error or the deadline ends it
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if let result = try AcpmuxStatusClient.detailedReply(to: id, in: line) { return result }
            }
            guard buffer.count < 1 << 20 else { throw AcpmuxServerPeer.Refusal.closed }
            buffer += try AcpmuxServerPeer.read(from: descriptor, until: until)
        }
    }
}
