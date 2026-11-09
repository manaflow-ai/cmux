import Foundation

/// Settings > Agents > Worktree Setup's session host operations
/// (design/worktree-setup.md): the project list, a project's worktree setup
/// (`git.worktree.setup`: the recipe the repository and the saved one make),
/// and saving the project's own recipe (`project.update` field `worktree`,
/// `null` clears it). The session host owns the recipe; this only carries it.
public struct WorktreeSetupClient: Sendable {
    /// The operations it sends; any other is refused before it is sent.
    public static let operations: Set<String> = ["project.list", "git.worktree.setup", "project.update"]

    public let connection: DaemonConnection

    public init(connection: DaemonConnection) {
        self.connection = connection
    }

    /// One of ``operations``: its result, or for `project.update` the mutation's value.
    public func send(operation: String, params: [String: JSONValue], idempotencyKey: String?) async throws -> JSONValue {
        guard Self.operations.contains(operation) else {
            throw DaemonError.command(cmd: operation, message: "not a worktree setup operation", code: "operation.unsupported")
        }
        let envelope: @Sendable (UInt64) -> ResourceRequestEnvelope = { id in
            ResourceRequestEnvelope(id: id, operation: operation, params: params, idempotencyKey: idempotencyKey)
        }
        if operation == "project.update" {
            return try await connection.resourceRequest(envelope, as: ResourceMutationResult<JSONValue>.self).value
        }
        return try await connection.resourceRequest(envelope, as: JSONValue.self)
    }
}
