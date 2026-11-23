import Foundation

/// A project's own actions (`project.actions.list`): the session host finds
/// the project's actions file from a folder, checks it and merges it with the
/// global actions. The app only carries the answer to the palette.
public struct ProjectActionsClient: Sendable {
    /// One action, as the session host checked it.
    public struct Action: Sendable, Hashable, Decodable {
        public enum Source: String, Sendable, Hashable, Decodable {
            case project, global
        }

        public var name: String
        public var source: Source
        public var title: String
        public var tooltip: String?
        public var command: String
        /// `newTabInCurrentPane` or `currentTerminal`.
        public var target: String
        /// The project folder a project action runs in; nil for a global one.
        public var cwd: String?
    }

    /// The folder's project and its actions.
    public struct Listing: Sendable, Hashable, Decodable {
        public var projectRoot: String?
        public var actions: [Action]

        enum CodingKeys: String, CodingKey {
            case projectRoot = "project_root"
            case actions
        }

        public init(projectRoot: String? = nil, actions: [Action] = []) {
            self.projectRoot = projectRoot
            self.actions = actions
        }
    }

    public let connection: DaemonConnection

    public init(connection: DaemonConnection) {
        self.connection = connection
    }

    /// The actions for `folder`, the project's own only (the global ones are
    /// already in the registry from the settings file).
    public func list(folder: String) async throws -> Listing {
        let params: [String: JSONValue] = ["path": .string(folder), "include_global": .bool(false)]
        return try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "project.actions.list", params: params, idempotencyKey: nil)
        }, as: Listing.self)
    }
}
