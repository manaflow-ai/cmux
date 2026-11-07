public import CmuxNextAgentPane
public import CmuxNextDaemon
public import Foundation

/// The agent pane's changes view reads git through the session host:
/// `git.diff`, `git.status`, `git.files.search` and `git.checkpoint.diff` with the chat session's
/// folder as `path`.
/// The reads use a daemon connection of their own. The daemon answers one
/// connection's requests in order, and a read can take seconds in a large
/// repository, so on the control connection it would hold terminal and
/// layout commands behind it. Commits and pushes (`git.commit`,
/// `git.push`) use a second connection, `writes`, for the same reason: a
/// hook or a slow remote holds one for up to two minutes.
public final class AgentPaneGitLink {
    private let daemon: DaemonService
    private let clientName: String
    /// The commits' and pushes' own connection, opened at the first write.
    private var writeLink: AgentPaneGitLink?
    private var opening: Task<DaemonConnection, any Error>?
    /// Reads and drops the connection's tree events: every handshake
    /// subscribes, and nothing here uses them.
    private var drain: Task<Void, Never>?

    public init(daemon: DaemonService, clientName: String = "cmux-next-agent-git") {
        self.daemon = daemon
        self.clientName = clientName
    }

    /// This Mac's link: the Changes view's git writes run here only for a chat it reads.
    public var isLocal: Bool { daemon.isLocal }

    /// The operation's result as JSON for the page. Throws an
    /// ``AgentPaneGitFailure``: the session host's resource error, or why
    /// the read got no answer (no connection, a timeout).
    public func read(_ request: AgentPaneGitRequest) async throws(AgentPaneGitFailure) -> Data {
        try await read(request.operation, params: request.sessionHostParams)
    }

    /// Session host read `operation` with `params` as sent (the Files page's `git.files.list`).
    public func read(_ operation: String, params: [String: JSONValue]) async throws(AgentPaneGitFailure) -> Data {
        let connection: DaemonConnection
        do {
            connection = try await self.connection()
        } catch {
            // The link did not open, so nothing was sent.
            throw AgentPaneGitFailure.notConnected
        }
        do {
            let result = try await GitResourceClient(connection: connection).read(operation, params: params)
            return try await Self.encode(result)
        } catch {
            throw AgentPaneGitFailure(reading: error)
        }
    }

    /// Typed command `request` on the read connection, with its own deadline: a Cloud machine's
    /// `fs.*` reads and writes for a file page (#25581), kept off the control connection as the git
    /// reads are. Throws `DaemonError.notConnected` when the link does not open (nothing was
    /// sent), else the command's own `DaemonError`.
    public func request<R: DaemonRequest>(_ request: R, timeout: Duration) async throws -> R.Response {
        let connection: DaemonConnection
        do {
            connection = try await self.connection()
        } catch {
            throw DaemonError.notConnected
        }
        return try await connection.request(request, timeout: timeout)
    }

    /// A whole diff, status or search result can be megabytes of JSON: encoded off the main actor.
    @concurrent private nonisolated static func encode(_ result: JSONValue) async throws -> Data {
        try JSONEncoder().encode(result)
    }

    /// The mutation's `MutationResult` as JSON for the page, run under the
    /// page's idempotency key. Throws like ``read(_:)``; a commit or push
    /// that may have run without an answer is `native.timed_out`, and the
    /// page's retry with the same key reports what it did.
    public func write(_ request: AgentPaneGitWrite, in cwd: String) async throws(AgentPaneGitFailure) -> Data {
        let connection: DaemonConnection
        do {
            let writes = writeLink ?? AgentPaneGitLink(daemon: daemon, clientName: clientName + "-write")
            writeLink = writes
            connection = try await writes.connection()
        } catch {
            throw AgentPaneGitFailure.notConnected
        }
        do {
            let result = try await GitResourceClient(connection: connection)
                .write(request.operation, params: request.sessionHostParams(cwd: cwd), idempotencyKey: request.key)
            return try await Self.encode(result)
        } catch {
            throw AgentPaneGitFailure(reading: error)
        }
    }

    /// Opens the connection on the first read; afterwards it reconnects by
    /// itself, finding a restarted daemon through the control connection's
    /// endpoint. A failed open is tried again by the next read.
    fileprivate func connection() async throws -> DaemonConnection {
        let task = opening ?? open()
        opening = task
        do {
            return try await task.value
        } catch {
            if opening == task { opening = nil }
            throw error
        }
    }

    /// Ends the link for good (its machine left the app): closes the connection, which ends the drain.
    public func close() {
        writeLink?.close()
        writeLink = nil
        let opening = opening
        self.opening = nil
        // task-owner: one bounded close of a connection nothing else holds
        Task { if let connection = try? await opening?.value { await connection.close() } }
    }

    private func open() -> Task<DaemonConnection, any Error> {
        let daemon = daemon
        let clientName = clientName
        return Task {
            let connection = DaemonConnection(
                configuration: DaemonConnection.Configuration(
                    clientName: clientName, treeEvents: .coarse, terminalEnvironment: nil),
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
        case .diff(let cwd, let scope, let includePatch, let options):
            ["path": .string(cwd), "scope": .string(scope.rawValue), "include_patch": .bool(includePatch)]
                .merging(options.sessionHostParams) { first, _ in first }
        case .status(let cwd):
            ["path": .string(cwd)]
        case .filesSearch(let cwd, let query, let limit):
            ["path": .string(cwd), "query": .string(query), "limit": .number(Double(limit))]
        case .checkpointDiff(let cwd, let from, let to, let includePatch, let options):
            ["path": .string(cwd), "from": .string(from), "include_patch": .bool(includePatch)]
                .merging(to.map { ["to": JSONValue.string($0)] } ?? [:]) { first, _ in first }
                .merging(options.sessionHostParams) { first, _ in first }
        }
    }
}

extension AgentPaneGitDiffOptions {
    /// `paths` and `context_lines` when the page named them.
    var sessionHostParams: [String: JSONValue] {
        var params: [String: JSONValue] = [:]
        if !paths.isEmpty { params["paths"] = .array(paths.map(JSONValue.string)) }
        if let contextLines { params["context_lines"] = .number(Double(contextLines)) }
        if let patchOffset { params["patch_offset"] = .string(String(patchOffset)) }
        if let patchRevision { params["patch_revision"] = .string(patchRevision) }
        return params
    }
}

extension AgentPaneGitWrite {
    /// The session host's params: `cwd` (the pane's session's folder, or a
    /// new chat's folder for a worktree) as `path`; the key travels in the
    /// envelope, not in the params.
    func sessionHostParams(cwd: String) -> [String: JSONValue] {
        switch self {
        case .commit(_, let message, let all, let includeUntracked, let expectedHead, _):
            var params: [String: JSONValue] = ["path": .string(cwd), "message": .string(message)]
            if all { params["all"] = .bool(true) }
            if includeUntracked { params["include_untracked"] = .bool(true) }
            if let expectedHead { params["expected_head"] = .string(expectedHead) }
            return params
        case .push(_, let expectedHead, _):
            var params: [String: JSONValue] = ["path": .string(cwd)]
            if let expectedHead { params["expected_head"] = .string(expectedHead) }
            return params
        case .worktree(_, let name, _):
            var params: [String: JSONValue] = ["path": .string(cwd)]
            if let name { params["name"] = .string(name) }
            return params
        case .worktreeApply:
            return ["path": .string(cwd)]
        case .worktreeRemove(_, let discard, _):
            var params: [String: JSONValue] = ["path": .string(cwd)]
            if discard { params["discard"] = .bool(true) }
            return params
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
