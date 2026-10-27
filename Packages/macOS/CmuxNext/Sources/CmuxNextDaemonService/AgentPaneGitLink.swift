public import CmuxNextAgentPane
public import CmuxNextDaemon
public import Foundation

/// What an ``AgentPaneGitLink`` needs of its machine's daemon service: ``DaemonService`` in the
/// app; a fake daemon in tests.
@MainActor
public protocol AgentPaneGitDaemon: AnyObject, Sendable {
    /// This Mac's daemon.
    var isLocal: Bool { get }
    /// Whether the connected daemon has `capability`.
    func supports(_ capability: String) -> Bool
    /// The app's control connection, after the first connect while the service is starting; nil
    /// when the daemon is not reachable (startup gave up, or the organization turned it off).
    func controlConnection() async -> DaemonConnection?
    /// The daemon's socket, for the connections of a daemon without
    /// ``AgentPaneGitLink/sharedConnectionCapability``.
    func endpoint() async throws -> DaemonEndpoint
}

extension DaemonService: AgentPaneGitDaemon {
    public func controlConnection() async -> DaemonConnection? {
        if policyBlock.isBlocked { return nil }
        if connection == nil, startup == .connecting, isStarting { await firstConnection() }
        return connection
    }
}

/// The agent pane's changes view reads git through the session host:
/// `git.diff`, `git.status`, `git.files.search` and `git.checkpoint.diff` with the chat session's
/// folder as `path`, and commits and pushes (`git.commit`, `git.push`) the same way.
///
/// They go on the app's control connection when the daemon has
/// ``sharedConnectionCapability``: it runs git off the connection's request thread, and a
/// connection's reads in a sequence apart from its writes, so a read that takes seconds in a large
/// repository holds no terminal or layout command, and a push held by a hook or a slow remote (up
/// to two minutes) holds no read. Chrome carries each interface of a renderer as an associated
/// interface on its one channel and runs each on its own sequence
/// (mojo/public/cpp/bindings/associated_receiver.h). An older daemon answers a connection's git
/// requests in order on its request thread, so there the reads and the writes each keep a
/// connection of their own (``AgentPaneGitConnection``).
public final class AgentPaneGitLink {
    /// The daemon runs git requests off the request thread, reads apart from writes
    /// (cmux-tui `git_ops/sequence.rs`).
    public static let sharedConnectionCapability = "git-shared-connection-v1"

    private let daemon: any AgentPaneGitDaemon
    private let reads: AgentPaneGitConnection
    private let writes: AgentPaneGitConnection

    public init(daemon: any AgentPaneGitDaemon, clientName: String = "cmux-next-agent-git") {
        self.daemon = daemon
        reads = AgentPaneGitConnection(daemon: daemon, clientName: clientName)
        writes = AgentPaneGitConnection(daemon: daemon, clientName: clientName + "-write")
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
        // Nothing was sent when no connection is open.
        let connection = try await self.connection(else: reads)
        do {
            let result = try await GitResourceClient(connection: connection).read(operation, params: params)
            return try await Self.encode(result)
        } catch {
            throw AgentPaneGitFailure(reading: error)
        }
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
        let connection = try await self.connection(else: writes)
        do {
            let result = try await GitResourceClient(connection: connection)
                .write(request.operation, params: request.sessionHostParams(cwd: cwd), idempotencyKey: request.key)
            return try await Self.encode(result)
        } catch {
            throw AgentPaneGitFailure(reading: error)
        }
    }

    /// The control connection, or `own`'s connection for a daemon without
    /// ``sharedConnectionCapability``. A daemon that gained it (handed off to a newer build) closes
    /// the link's own connections.
    private func connection(else own: AgentPaneGitConnection) async throws(AgentPaneGitFailure) -> DaemonConnection {
        guard let control = await daemon.controlConnection() else { throw AgentPaneGitFailure.notConnected }
        if daemon.supports(Self.sharedConnectionCapability) {
            reads.close()
            writes.close()
            return control
        }
        do {
            return try await own.connection()
        } catch {
            throw AgentPaneGitFailure.notConnected
        }
    }

    /// Ends the link for good (its machine left the app): closes the connections it opened. The
    /// control connection is the service's.
    public func close() {
        reads.close()
        writes.close()
    }
}

/// A git link's own connection to a daemon without
/// ``AgentPaneGitLink/sharedConnectionCapability``, opened at its first request.
final class AgentPaneGitConnection {
    private let daemon: any AgentPaneGitDaemon
    private let clientName: String
    private var opening: Task<DaemonConnection, any Error>?

    init(daemon: any AgentPaneGitDaemon, clientName: String) {
        self.daemon = daemon
        self.clientName = clientName
    }

    /// Opens the connection on the first request; afterwards it reconnects by itself, finding a
    /// restarted daemon through the control connection's endpoint. A failed open is tried again
    /// by the next request.
    func connection() async throws -> DaemonConnection {
        let task = opening ?? open()
        opening = task
        do {
            return try await task.value
        } catch {
            if opening == task { opening = nil }
            throw error
        }
    }

    /// Closes the connection, if one is open or opening.
    func close() {
        guard let opening else { return }
        self.opening = nil
        // task-owner: one bounded close of a connection nothing else holds
        Task { if let connection = try? await opening.value { await connection.close() } }
    }

    private func open() -> Task<DaemonConnection, any Error> {
        let daemon = daemon
        let clientName = clientName
        return Task {
            let connection = DaemonConnection(
                configuration: DaemonConnection.Configuration(
                    clientName: clientName, treeEvents: .coarse, terminalEnvironment: nil),
                endpointProvider: { try await daemon.endpoint() })
            // Every handshake subscribes, and nothing here uses the events: dropped as they come.
            connection.discardEvents()
            do {
                try await connection.start()
            } catch {
                await connection.close()
                throw error
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
