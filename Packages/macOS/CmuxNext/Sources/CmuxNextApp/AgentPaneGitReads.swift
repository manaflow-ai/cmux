import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// The agent pane's changes view reads git through the session host:
/// `git.diff`, `git.status`, `git.files.search` and `git.checkpoint.diff` with the chat session's
/// folder as `path`.
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

    /// The operation's result as JSON for the page. Throws an
    /// ``AgentPaneGitFailure``: the session host's resource error, or why
    /// the read got no answer (no connection, a timeout).
    func read(_ request: AgentPaneGitRequest) async throws(AgentPaneGitFailure) -> Data {
        let connection: DaemonConnection
        do {
            connection = try await self.connection()
        } catch {
            // The link did not open, so nothing was sent.
            throw AgentPaneGitFailure.notConnected
        }
        do {
            let result = try await GitResourceClient(connection: connection).read(request.operation, params: request.sessionHostParams)
            return try JSONEncoder().encode(result)
        } catch {
            throw AgentPaneGitFailure(reading: error)
        }
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
        case .filesSearch(let cwd, let query, let limit):
            ["path": .string(cwd), "query": .string(query), "limit": .number(Double(limit))]
        case .checkpointDiff(let cwd, let from, let to, let includePatch):
            ["path": .string(cwd), "from": .string(from), "include_patch": .bool(includePatch)]
                .merging(to.map { ["to": JSONValue.string($0)] } ?? [:]) { first, _ in first }
        }
    }
}

extension AgentPaneGitFailure {
    /// The failure the page gets for an error of a sent git read. A resource
    /// error the session host answered keeps its code, details and
    /// retryable; a request that may have gone out unanswered (a timeout, the
    /// connection closing while it was pending) is `native.timed_out`.
    nonisolated init(reading error: any Error) {
        switch error {
        case let failure as AgentPaneGitFailure:
            self = failure
        case DaemonError.command(_, _, let code?, let details, let retryable):
            let json = details.flatMap { try? JSONEncoder().encode($0) }
            self.init(code: code, details: json, retryable: retryable, origin: .sessionHost)
        case DaemonError.notConnected:
            self = .notConnected
        case DaemonError.timedOut, DaemonError.connectionClosed, DaemonError.daemonShutdown:
            self = .timedOut
        default:
            self = .failed
        }
    }
}
