import Foundation

/// The device's project list as protocol-v2 state operations
/// (`project-list-v1`, plans/cmux-next/projects.md section 6). The daemon owns
/// the merge, the refusals and the user's overlay; callers only report.
public struct ProjectStateClient: Sendable {
    public let connection: DaemonConnection

    public init(connection: DaemonConnection) {
        self.connection = connection
    }

    /// `source` reports `entries` (`{path, last_used_ms}`, the time a decimal
    /// string); with `complete`, they are everything the source lists.
    public func observe(source: String, entries: [JSONValue], complete: Bool, idempotencyKey: String) async throws {
        _ = try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "project.observe",
                                    params: ["source": .string(source), "entries": .array(entries), "complete": .bool(complete)],
                                    idempotencyKey: idempotencyKey)
        }, as: ResourceMutationResult<JSONValue>.self)
    }

    /// App launch or activation: the folders the app checked (`existing`,
    /// `gone`); the daemon also rereads the editor sources.
    public func sync(existing: [String], gone: [String], idempotencyKey: String) async throws {
        _ = try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "project.sync",
                                    params: ["existing": .array(existing.map(JSONValue.string)), "gone": .array(gone.map(JSONValue.string))],
                                    idempotencyKey: idempotencyKey)
        }, as: ResourceMutationResult<JSONValue>.self)
    }
}
