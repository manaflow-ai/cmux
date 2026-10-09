import Foundation

/// The session host's git operations (`git.diff`, `git.status`, and the
/// mutations `git.commit` and `git.push`; cmux-tui
/// `spec/resource-operations-v2.json`) for a folder named by its absolute
/// `path`. Results stay JSON: the agent pane's page reads their
/// snake_case fields itself. Its own type, not a `DaemonConnection`
/// extension (that type's line budget is frozen).
public struct GitResourceClient: Sendable {
    public let connection: DaemonConnection

    /// A git read walks the working tree, so it may take longer than a
    /// control command's deadline. The session host bounds each git process
    /// at 20 s, and a branch diff runs a few in turn.
    public static let timeout: Duration = .seconds(30)

    /// The session host stops a commit or push after 120 s (a hook or the
    /// remote can be slow); the reply gets a margin beyond that.
    public static let writeTimeout: Duration = .seconds(150)

    public init(connection: DaemonConnection) {
        self.connection = connection
    }

    /// Runs `operation` with `params` (`path` plus the operation's fields)
    /// and returns its `result`.
    public func read(_ operation: String, params: [String: JSONValue]) async throws -> JSONValue {
        try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: operation, params: params, idempotencyKey: nil)
        }, as: JSONValue.self, timeout: Self.timeout)
    }

    /// Runs the mutation `operation` with `params` under `idempotencyKey` and
    /// returns its `MutationResult`. A retry with the same key and params
    /// replays the first result; it never commits or pushes twice.
    public func write(_ operation: String, params: [String: JSONValue], idempotencyKey: String) async throws -> JSONValue {
        try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: operation, params: params, idempotencyKey: idempotencyKey)
        }, as: JSONValue.self, timeout: Self.writeTimeout)
    }
}
