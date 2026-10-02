import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// The agent pane's changes view reads git through the session host:
/// `git.diff` and `git.status` with the chat session's folder as `path`.
/// The reads use a daemon connection of their own. The daemon answers one
/// connection's requests in order, and a read can take seconds in a large
/// repository, so on the control connection it would hold terminal and
/// layout commands behind it.
final class AgentPaneGitLink {
    private let daemon: DaemonService
    private var opening: Task<DaemonConnection, any Error>?
    /// Reads and drops the connection's tree events: every handshake
    /// subscribes, and nothing here uses them.
    private var drain: Task<Void, Never>?

    init(daemon: DaemonService) {
        self.daemon = daemon
    }

    /// The operation's result as JSON for the page; throws when the daemon
    /// is away or the read fails (no repository, a timeout).
    func read(_ request: AgentPaneGitRequest) async throws -> Data {
        let connection = try await connection()
        let result = try await GitResourceClient(connection: connection).read(request.operation, params: request.sessionHostParams)
        return try JSONEncoder().encode(result)
    }

    /// Opens the connection on the first read; afterwards it reconnects by
    /// itself, finding a restarted daemon through the control connection's
    /// endpoint. A failed open is tried again by the next read.
    private func connection() async throws -> DaemonConnection {
        let task = opening ?? open()
        opening = task
        do {
            return try await task.value
        } catch {
            if opening == task { opening = nil }
            throw error
        }
    }

    private func open() -> Task<DaemonConnection, any Error> {
        let daemon = daemon
        return Task {
            let connection = DaemonConnection(
                configuration: DaemonConnection.Configuration(
                    clientName: "cmux-next-agent-git", treeEvents: .coarse, terminalEnvironment: nil),
                endpointProvider: { try await daemon.endpoint() })
            do {
                try await connection.start()
            } catch {
                await connection.close()
                throw error
            }
            drain = Task {
                do {
                    for try await _ in connection.events {}
                } catch {}
            }
            return connection
        }
    }
}

extension AgentPaneGitRequest {
    /// The session host's params (cmux-tui `spec/resource-operations-v2.json`).
    var sessionHostParams: [String: JSONValue] {
        switch self {
        case .diff(let cwd, let scope, let includePatch):
            ["path": .string(cwd), "scope": .string(scope.rawValue), "include_patch": .bool(includePatch)]
        case .status(let cwd):
            ["path": .string(cwd)]
        }
    }
}
