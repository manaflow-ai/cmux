public import Foundation
import os

/// Produces the handshake for a pane. The App picks the live acpmux host or
/// the mock; the pane never knows which.
public nonisolated protocol AgentPaneHostProviding: Sendable {
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake
    /// Starts the daemon before a page is visible. Callers may treat this as
    /// best effort because the normal page handshake still reports failures.
    func prewarm() async throws
    /// The handshake for a page that lost its daemon. Never starts one, so a
    /// daemon the user stopped stays stopped.
    func reconnectHandshake(sessionId: String?) async throws -> AgentPaneHandshake
}

extension AgentPaneHostProviding {
    /// Hosts without a daemon answer a reconnect like a first handshake.
    public func reconnectHandshake(sessionId: String?) async throws -> AgentPaneHandshake {
        try await handshake(sessionId: sessionId)
    }

    public func prewarm() async throws {}
}

/// Why the live host could not produce a handshake.
public nonisolated enum AgentPaneHostError: Error, Equatable, Sendable {
    /// No `acpmux` executable in the app bundle, on `PATH`, or in the usual
    /// install directories.
    case acpmuxNotFound
    /// The daemon could not be started or reported no WebSocket listener;
    /// details are in its log.
    case daemonFailed(logPath: String)
    /// Nothing listens on the socket and this handshake may not start a
    /// daemon (``AgentPaneHostProviding/reconnectHandshake(sessionId:)``).
    case daemonStopped
    case timedOut
}

/// Finds the running acpmux daemon, or starts one, and hands the page its
/// WebSocket endpoint. Concurrent handshakes (several panes opening at once)
/// share one lookup, so they never race to spawn two daemons. A reconnect
/// only looks; it never starts a daemon.
public actor AcpmuxHost: AgentPaneHostProviding {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")
    private let resolveEnvironment: @Sendable () -> AcpmuxEnvironment?
    /// The Computer Use socket and agent token now (`AcpmuxEnvironment.computerUse`),
    /// read at each daemon start, since Computer Use turns on and off while the app runs.
    private let computerUse: @Sendable () -> [String: String]
    /// Kept only once found, so acpmux installed after the first chat is picked up.
    private var environment: AcpmuxEnvironment?
    /// The lookup in flight, by whether it may start a daemon.
    private var inFlight: [Bool: Task<AcpmuxWebEndpoint, any Error>] = [:]

    public init(environment: AcpmuxEnvironment?) {
        self.resolveEnvironment = { environment }
        self.computerUse = { [:] }
    }

    /// Looks for acpmux (bundled, PATH, install directories) on the actor,
    /// off the main thread, at the first handshake that needs it.
    public init(resolve: @escaping @Sendable () -> AcpmuxEnvironment?,
                computerUse: @escaping @Sendable () -> [String: String] = { [:] }) {
        self.resolveEnvironment = resolve
        self.computerUse = computerUse
    }

    public func handshake(sessionId: String?) async throws -> AgentPaneHandshake {
        .acpmux(connection(try await endpoint(startsDaemon: true)), sessionId: sessionId)
    }

    public func reconnectHandshake(sessionId: String?) async throws -> AgentPaneHandshake {
        .acpmux(connection(try await endpoint(startsDaemon: false)), sessionId: sessionId)
    }

    /// The host socket's connection, with this daemon launch's LocalApp token read now, on the
    /// actor (it changes at every launch, so it is read at every handshake and reconnect).
    private func connection(_ endpoint: AcpmuxWebEndpoint) -> AcpmuxConnection {
        AcpmuxConnection(endpoint: endpoint, home: environment?.home, socketPath: environment?.socketPath)
    }

    public func prewarm() async throws {
        _ = try await endpoint(startsDaemon: true)
    }

    private func endpoint(startsDaemon: Bool) async throws -> AcpmuxWebEndpoint {
        if let task = inFlight[startsDaemon] { return try await task.value }
        // A reconnect during a start waits for that daemon instead of
        // reporting it stopped.
        if !startsDaemon, let task = inFlight[true] { return try await task.value }
        if environment == nil { environment = resolveEnvironment() }
        guard var environment else {
            Self.logger.error("acpmux environment unresolved startsDaemon=\(startsDaemon, privacy: .public)")
            throw AgentPaneHostError.acpmuxNotFound
        }
        environment.computerUse = computerUse()
        Self.logger.info("acpmux environment resolved executable=\(environment.executable.path, privacy: .public) home=\(environment.home.path, privacy: .public) socket=\(environment.socketPath, privacy: .public) startsDaemon=\(startsDaemon, privacy: .public)")
        // task-owner: stored in inFlight and cleared when it settles; callers await its value
        let task = Task { try await Self.findOrStart(environment, startsDaemon: startsDaemon) }
        inFlight[startsDaemon] = task
        defer { if inFlight[startsDaemon] == task { inFlight[startsDaemon] = nil } }
        return try await task.value
    }

    private static func findOrStart(_ environment: AcpmuxEnvironment, startsDaemon: Bool) async throws -> AcpmuxWebEndpoint {
        do {
            let status = try await AcpmuxStatusClient.status(socketPath: environment.socketPath)
            // After an update the daemon may be the previous build's: hand it
            // off (its agents keep running under their hosts) and start ours.
            guard startsDaemon, await AcpmuxVersionHandoff.handOffIfStale(status, environment: environment) else {
                return try status.endpoint()
            }
        } catch AcpmuxStatusClient.Failure.unreachable {
            logger.info("acpmux status unreachable socket=\(environment.socketPath, privacy: .public) startsDaemon=\(startsDaemon, privacy: .public)")
            // Nothing listens on the socket: start a daemon below, unless
            // the user stopped it.
            guard startsDaemon else { throw AgentPaneHostError.daemonStopped }
        } catch AcpmuxStatusClient.Failure.noWebSocket {
            logger.error("acpmux status returned no websocket socket=\(environment.socketPath, privacy: .public)")
            throw AgentPaneHostError.daemonFailed(logPath: environment.logPath)
        } catch is AgentPaneDeadlineExceeded {
            logger.error("acpmux status timed out socket=\(environment.socketPath, privacy: .public)")
            throw AgentPaneHostError.timedOut
        } catch {
            logger.error("acpmux status failed error=\(String(describing: error), privacy: .public)")
            throw AgentPaneHostError.daemonFailed(logPath: environment.logPath)
        }
        do {
            return try await AcpmuxDaemonLauncher.launch(environment)
        } catch AcpmuxDaemonLauncher.Failure.exited {
            logger.error("acpmux launcher exited before ready log=\(environment.logPath, privacy: .public)")
            // Another client may have started the daemon first; the loser
            // exits because the socket is taken. Ask the winner.
            do {
                return try await AcpmuxStatusClient.endpoint(socketPath: environment.socketPath)
            } catch {
                throw AgentPaneHostError.daemonFailed(logPath: environment.logPath)
            }
        } catch is AgentPaneDeadlineExceeded {
            logger.error("acpmux launcher timed out log=\(environment.logPath, privacy: .public)")
            throw AgentPaneHostError.timedOut
        } catch {
            logger.error("acpmux launcher failed error=\(String(describing: error), privacy: .public) log=\(environment.logPath, privacy: .public)")
            throw AgentPaneHostError.daemonFailed(logPath: environment.logPath)
        }
    }
}
