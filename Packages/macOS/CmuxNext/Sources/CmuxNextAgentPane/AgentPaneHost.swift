public import Foundation

/// Produces the handshake for a pane. The App picks the live acpmux host or
/// the mock; the pane never knows which.
public nonisolated protocol AgentPaneHostProviding: Sendable {
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake
}

/// Why the live host could not produce a handshake.
public nonisolated enum AgentPaneHostError: Error, Equatable, Sendable {
    /// No `acpmux` executable in the app bundle, on `PATH`, or in the usual
    /// install directories.
    case acpmuxNotFound
    /// The daemon could not be started or reported no WebSocket listener;
    /// details are in its log.
    case daemonFailed(logPath: String)
    case timedOut
}

/// Finds the running acpmux daemon, or starts one, and hands the page its
/// WebSocket endpoint. Concurrent handshakes (several panes opening at once)
/// share one lookup, so they never race to spawn two daemons.
public actor AcpmuxHost: AgentPaneHostProviding {
    private let environment: AcpmuxEnvironment?
    private var inFlight: Task<AcpmuxWebEndpoint, any Error>?

    public init(environment: AcpmuxEnvironment?) {
        self.environment = environment
    }

    public func handshake(sessionId: String?) async throws -> AgentPaneHandshake {
        .acpmux(try await endpoint(), sessionId: sessionId)
    }

    private func endpoint() async throws -> AcpmuxWebEndpoint {
        if let inFlight { return try await inFlight.value }
        guard let environment else { throw AgentPaneHostError.acpmuxNotFound }
        // task-owner: stored in inFlight and cleared when it settles; callers await its value
        let task = Task { try await Self.findOrStart(environment) }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private static func findOrStart(_ environment: AcpmuxEnvironment) async throws -> AcpmuxWebEndpoint {
        do {
            return try await AcpmuxStatusClient.endpoint(socketPath: environment.socketPath)
        } catch AcpmuxStatusClient.Failure.unreachable {
            // Nothing listens on the socket: start a daemon below.
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
