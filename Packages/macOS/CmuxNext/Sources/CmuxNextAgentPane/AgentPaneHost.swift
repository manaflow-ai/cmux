public import Foundation

/// Produces the handshake for a pane. The App picks the live acpmux host or
/// the mock; the pane never knows which.
public nonisolated protocol AgentPaneHostProviding: Sendable {
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake
    /// The handshake for a page that lost its daemon. Never starts one, so a
    /// daemon the user stopped stays stopped.
    func reconnectHandshake(sessionId: String?) async throws -> AgentPaneHandshake
}

extension AgentPaneHostProviding {
    /// Hosts without a daemon answer a reconnect like a first handshake.
    public func reconnectHandshake(sessionId: String?) async throws -> AgentPaneHandshake {
        try await handshake(sessionId: sessionId)
    }
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
    private let resolveEnvironment: @Sendable () -> AcpmuxEnvironment?
    /// Kept only once found, so acpmux installed after the first chat is picked up.
    private var environment: AcpmuxEnvironment?
    /// The lookup in flight, by whether it may start a daemon.
    private var inFlight: [Bool: Task<AcpmuxWebEndpoint, any Error>] = [:]

    public init(environment: AcpmuxEnvironment?) {
        self.resolveEnvironment = { environment }
    }

    /// Looks for acpmux (bundled, PATH, install directories) on the actor,
    /// off the main thread, at the first handshake that needs it.
    public init(resolve: @escaping @Sendable () -> AcpmuxEnvironment?) {
        self.resolveEnvironment = resolve
    }

    public func handshake(sessionId: String?) async throws -> AgentPaneHandshake {
        .acpmux(try await endpoint(startsDaemon: true), sessionId: sessionId)
    }

    public func reconnectHandshake(sessionId: String?) async throws -> AgentPaneHandshake {
        .acpmux(try await endpoint(startsDaemon: false), sessionId: sessionId)
    }

    private func endpoint(startsDaemon: Bool) async throws -> AcpmuxWebEndpoint {
        if let task = inFlight[startsDaemon] { return try await task.value }
        // A reconnect during a start waits for that daemon instead of
        // reporting it stopped.
        if !startsDaemon, let task = inFlight[true] { return try await task.value }
        if environment == nil { environment = resolveEnvironment() }
        guard let environment else { throw AgentPaneHostError.acpmuxNotFound }
        // task-owner: stored in inFlight and cleared when it settles; callers await its value
        let task = Task { try await Self.findOrStart(environment, startsDaemon: startsDaemon) }
        inFlight[startsDaemon] = task
        defer { if inFlight[startsDaemon] == task { inFlight[startsDaemon] = nil } }
        return try await task.value
    }

    private static func findOrStart(_ environment: AcpmuxEnvironment, startsDaemon: Bool) async throws -> AcpmuxWebEndpoint {
        do {
            return try await AcpmuxStatusClient.endpoint(socketPath: environment.socketPath)
        } catch AcpmuxStatusClient.Failure.unreachable {
            // Nothing listens on the socket: start a daemon below, unless
            // the user stopped it.
            guard startsDaemon else { throw AgentPaneHostError.daemonStopped }
        } catch AcpmuxStatusClient.Failure.noWebSocket {
            throw AgentPaneHostError.daemonFailed(logPath: environment.logPath)
        } catch is AgentPaneDeadlineExceeded {
            throw AgentPaneHostError.timedOut
        } catch {
            throw AgentPaneHostError.daemonFailed(logPath: environment.logPath)
        }
        do {
            return try await AcpmuxDaemonLauncher.launch(environment)
        } catch AcpmuxDaemonLauncher.Failure.exited {
            // Another client may have started the daemon first; the loser
            // exits because the socket is taken. Ask the winner.
            do {
                return try await AcpmuxStatusClient.endpoint(socketPath: environment.socketPath)
            } catch {
                throw AgentPaneHostError.daemonFailed(logPath: environment.logPath)
            }
        } catch is AgentPaneDeadlineExceeded {
            throw AgentPaneHostError.timedOut
        } catch {
            throw AgentPaneHostError.daemonFailed(logPath: environment.logPath)
        }
    }
}
