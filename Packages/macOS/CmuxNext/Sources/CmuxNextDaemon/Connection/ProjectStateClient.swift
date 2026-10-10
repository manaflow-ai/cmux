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

    /// The listed folders (`project.list`): pinned first, then by last use,
    /// hidden ones left out; `query` filters by path or name.
    public func listPaths(query: String?, limit: Int) async throws -> [String] {
        var params: [String: JSONValue] = ["limit": .number(Double(limit))]
        if let query, !query.isEmpty { params["query"] = .string(query) }
        let fields = params
        let result = try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "project.list", params: fields, idempotencyKey: nil)
        }, as: JSONValue.self)
        guard case .object(let object) = result, case .array(let projects)? = object["projects"] else { return [] }
        return projects.compactMap { project in
            guard case .object(let fields) = project, case .string(let path)? = fields["path"] else { return nil }
            return path
        }
    }

    /// The user picked `path` (`project.add`): it is listed as the user's own.
    public func add(path: String, idempotencyKey: String) async throws {
        _ = try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "project.add", params: ["path": .string(path)],
                                    idempotencyKey: idempotencyKey)
        }, as: ResourceMutationResult<JSONValue>.self)
    }
}
