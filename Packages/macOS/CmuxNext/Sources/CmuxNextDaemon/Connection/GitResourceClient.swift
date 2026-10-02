import Foundation

/// The session host's git operations (cmux-tui
/// `spec/resource-operations-v2.json`) for a folder named by its absolute
/// `path`: the reads `git.diff`, `git.status`, `git.checkpoint.get` and
/// `git.checkpoint.list`, and the checkpoint mutations `create`, `pin` and
/// `unpin`. Results stay JSON: the agent pane's page reads their snake_case
/// fields itself. Its own type, not a `DaemonConnection`
/// extension (that type's line budget is frozen).
public struct GitResourceClient: Sendable {
    public let connection: DaemonConnection

    /// A git read walks the working tree, so it may take longer than a
    /// control command's deadline. The session host bounds each git process
    /// at 20 s, and a branch diff runs a few in turn.
    public static let timeout: Duration = .seconds(30)

    /// A checkpoint mutation hashes and stores the working tree before it
    /// publishes, so it gets longer than a read. A miss leaves its outcome
    /// unknown; the caller looks it up by key before retrying.
    public static let mutationTimeout: Duration = .seconds(120)

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

    /// Runs the mutation `operation` with `params` under `idempotencyKey`,
    /// which goes in the request envelope, not in `params`. Returns the
    /// catalog's `MutationResult`: the value, revision and whether the
    /// session host replayed an earlier result for the key.
    public func mutate(_ operation: String, params: [String: JSONValue], idempotencyKey: String,
                       timeout: Duration = Self.mutationTimeout) async throws -> ResourceMutationResult<JSONValue> {
        try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: operation, params: params, idempotencyKey: idempotencyKey)
        }, as: ResourceMutationResult<JSONValue>.self, timeout: timeout)
    }
}
