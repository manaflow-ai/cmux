import Foundation

/// Home on the workspace store (plans/cmux-next/home.md 7): the one home
/// workspace (`workspace-kind-v1`). Conversation tabs: `NewConversationTabRequest`.
public struct HomeWorkspaceClient: Sendable {
    public let connection: DaemonConnection

    public init(_ connection: DaemonConnection) {
        self.connection = connection
    }

    /// `workspace.ensure_home` result value.
    public struct EnsuredHome: Decodable, Sendable, Equatable {
        public var workspaceID: ResourceID
        enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id" }
    }

    /// The store's home workspace, created on the first call and the same
    /// workspace on every later one (any key replays it). Requires `workspace-kind-v1`.
    /// `displayName` is the Home app's English name, for the stored name of
    /// its companion workspace ("Home Tabs", `app-screens-v1`).
    public func ensureHome(displayName: String? = nil) async throws -> ResourceID {
        let key = "cmux-next-home-" + UUID().uuidString.lowercased()
        let params: [String: JSONValue] = displayName.map { ["display_name": .string($0)] } ?? [:]
        let result = try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "workspace.ensure_home", params: params, idempotencyKey: key)
        }, as: ResourceMutationResult<EnsuredHome>.self)
        return result.value.workspaceID
    }
}

/// A tab that shows `conversation` of the `owner` conversation owner
/// (`conversation-tabs-v1`). With `origin` and `mutationID` a retry returns
/// the first tab (`replayed`).
public struct NewConversationTabRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var surface: SurfaceID
        public var tabResourceID: ResourceID?
        public var replayed: Bool
        enum CodingKeys: String, CodingKey {
            case surface, replayed
            case tabResourceID = "tab_resource_id"
        }
    }
    public static let command = "new-conversation-tab"
    public var conversation: String
    public var owner: String
    public var pane: PaneID?
    /// Exclusive with `pane`: the workspace's active pane, or its first pane
    /// when it is empty (the home workspace starts empty).
    public var workspace: WorkspaceHandle?
    public var origin: String?
    public var mutationID: String?

    public init(conversation: String, owner: String = "local", pane: PaneID? = nil, workspace: WorkspaceHandle? = nil,
                origin: String? = nil, mutationID: String? = nil) {
        self.conversation = conversation
        self.owner = owner
        self.pane = pane
        self.workspace = workspace
        self.origin = origin
        self.mutationID = mutationID
    }
}
