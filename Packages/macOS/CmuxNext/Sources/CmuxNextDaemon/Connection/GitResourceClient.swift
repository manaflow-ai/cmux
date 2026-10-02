import Foundation

/// The session host's read-only git operations (`git.diff`, `git.status`;
/// cmux-tui `spec/resource-operations-v2.json`) for a folder named by its
/// absolute `path`. Results stay JSON: the agent pane's page reads their
/// snake_case fields itself. Its own type, not a `DaemonConnection`
/// extension (that type's line budget is frozen).
public struct GitResourceClient: Sendable {
    public let connection: DaemonConnection

    /// A git read walks the working tree, so it may take longer than a
    /// control command's deadline.
    public static let timeout: Duration = .seconds(15)

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
}
