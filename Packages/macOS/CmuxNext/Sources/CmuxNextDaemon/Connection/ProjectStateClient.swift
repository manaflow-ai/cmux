import Foundation

/// The device's project list as protocol-v2 state operations
/// (`project-list-v1`, plans/cmux-next/projects.md section 6). The daemon owns
/// the merge, the refusals and the user's overlay; callers only report.
public struct ProjectStateClient: Sendable {
    public let connection: DaemonConnection

    public init(connection: DaemonConnection) {
        self.connection = connection
    }

    /// The listed folders (`project.list`): pinned first, then by last use,
    /// hidden ones and folders gone from disk (`state: missing`) left out;
    /// `query` filters by path or name, a leading `~` read as `home`. A reply
    /// without a project array throws, so the caller can fall back.
    public func listPaths(query: String?, limit: Int, home: String? = nil) async throws -> [String] {
        try await list(query: query, limit: limit, home: home).paths
    }

    /// ``listPaths(query:limit:home:)`` and whether the store holds any project at all
    /// (`sources` counts, `project-sources-v1`; hidden and removed projects count), so a
    /// caller can tell "nothing imported yet" from "the user removed them".
    public func list(query: String?, limit: Int, home: String? = nil) async throws -> (paths: [String], storeHasProjects: Bool) {
        var params: [String: JSONValue] = ["limit": .number(Double(limit))]
        if let query, !query.isEmpty {
            let expanded = query == "~" || query.hasPrefix("~/") ? (home ?? NSHomeDirectory()) + query.dropFirst() : query
            params["query"] = .string(expanded)
        }
        let fields = params
        let result = try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "project.list", params: fields, idempotencyKey: nil)
        }, as: JSONValue.self)
        guard case .object(let object) = result, case .array(let projects)? = object["projects"] else {
            throw ProjectListReplyError()
        }
        let paths: [String] = projects.compactMap { project in
            guard case .object(let fields) = project, case .string(let path)? = fields["path"] else { return nil }
            if case .string("missing")? = fields["state"] { return nil }
            return path
        }
        var counted = false
        if case .array(let sources)? = object["sources"] {
            counted = sources.contains { source in
                guard case .object(let fields) = source, case .number(let count)? = fields["projects"] else { return false }
                return count > 0
            }
        }
        return (paths, !projects.isEmpty || counted)
    }

    /// The user picked `path` (`project.add`): it is listed as the user's own.
    public func add(path: String, idempotencyKey: String) async throws {
        _ = try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "project.add", params: ["path": .string(path)],
                                    idempotencyKey: idempotencyKey)
        }, as: ResourceMutationResult<JSONValue>.self)
    }
}

/// A `project.list` reply without its `projects` array.
public struct ProjectListReplyError: Error, Sendable {
    public init() {}
}
