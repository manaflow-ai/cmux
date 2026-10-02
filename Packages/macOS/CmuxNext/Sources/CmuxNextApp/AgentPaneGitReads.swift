import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// The agent pane's git requests run on the session host with the chat
/// session's folder as `path`: the changes view's `git.diff` and
/// `git.status`, and the checkpoint review's `git.checkpoint.*`. They use a
/// daemon connection of their own. The daemon answers one connection's
/// requests in order, and a read or a capture can take seconds in a large
/// repository, so on the control connection it would hold terminal and
/// layout commands behind it.
final class AgentPaneGitLink {
    private let endpoint: DaemonConnection.EndpointProvider
    private var opening: Task<DaemonConnection, any Error>?
    /// Reads and drops the connection's tree events: every handshake
    /// subscribes, and nothing here uses them.
    private var drain: Task<Void, Never>?

    /// A link that finds the daemon through the control connection's
    /// endpoint, so it follows a restarted daemon.
    convenience init(daemon: DaemonService) {
        self.init(endpoint: { try await daemon.endpoint() })
    }

    /// - Parameter endpoint: Where the daemon listens, asked on each connect.
    init(endpoint: @escaping DaemonConnection.EndpointProvider) {
        self.endpoint = endpoint
    }

    /// The request's answer as JSON for the page. Throws an
    /// ``AgentPaneGitFailure``: the session host's resource error, or why
    /// the request got no answer (no connection, a timeout).
    ///
    /// A read answers the operation's result. A mutation answers
    /// `{result, revision, replayed}`. `git.capabilities` answers
    /// `{checkpoints}` and never throws: a daemon it cannot reach serves
    /// nothing.
    func run(_ request: AgentPaneGitRequest) async throws(AgentPaneGitFailure) -> Data {
        if case .capabilities = request {
            return await capabilities()
        }
        let connection: DaemonConnection
        do {
            connection = try await self.connection()
        } catch {
            // The link did not open, so nothing was sent.
            throw AgentPaneGitFailure.notConnected
        }
        let client = GitResourceClient(connection: connection)
        if let key = request.idempotencyKey {
            do {
                let reply = try await client.mutate(request.operation, params: request.sessionHostParams, idempotencyKey: key)
                return try Self.pageEnvelope(reply)
            } catch {
                throw AgentPaneGitFailure(mutating: error)
            }
        }
        do {
            let result = try await client.read(request.operation, params: request.sessionHostParams)
            return try JSONEncoder().encode(result)
        } catch {
            throw AgentPaneGitFailure(reading: error)
        }
    }

    /// `{checkpoints}` from the identify of the daemon this link reaches,
    /// opening the link first; false when it cannot connect.
    private func capabilities() async -> Data {
        let connection = try? await self.connection()
        let identity = await connection?.identity
        return Self.capabilitiesReply(identity)
    }

    /// `{"checkpoints": true}` only when `identity` advertises
    /// `git-checkpoints-v1`.
    nonisolated static func capabilitiesReply(_ identity: DaemonIdentity?) -> Data {
        let supported = identity?.supports(DaemonCapabilities.shared.gitCheckpoints) == true
        return Data(#"{"checkpoints":\#(supported)}"#.utf8)
    }

    /// The page's mutation envelope (`MutationEnvelope` in the checkpoint
    /// client): the catalog's `value` as `result`, with its `revision` and
    /// `replayed`. A missing `replayed` is a first result.
    nonisolated static func pageEnvelope(_ reply: ResourceMutationResult<JSONValue>) throws -> Data {
        var envelope: [String: JSONValue] = ["result": reply.value, "replayed": .bool(reply.replayed ?? false)]
        if let revision = reply.revision { envelope["revision"] = .string(revision) }
        return try JSONEncoder().encode(JSONValue.object(envelope))
    }

    /// Opens the connection on the first request; afterwards it reconnects
    /// by itself. A failed open is tried again by the next request.
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
        let endpoint = endpoint
        return Task {
            let connection = DaemonConnection(
                configuration: DaemonConnection.Configuration(
                    clientName: "cmux-next-agent-git", treeEvents: .coarse, terminalEnvironment: nil),
                endpointProvider: endpoint)
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
        case .capabilities:
            [:]
        case .checkpoint(let checkpoint):
            checkpoint.sessionHostParams
        }
    }
}
