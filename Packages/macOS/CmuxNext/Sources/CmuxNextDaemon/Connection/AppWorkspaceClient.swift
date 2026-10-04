import Foundation

/// App screens on the workspace store (plans/cmux-next/app-screens.md 2):
/// one workspace of workspace kind `app` per app, holding one screen of the
/// asked screen kind with the app's `app` tab. Requires `app-screens-v1`.
public struct AppWorkspaceClient: Sendable {
    public let connection: DaemonConnection

    public init(_ connection: DaemonConnection) {
        self.connection = connection
    }

    /// The screen kind `workspace.ensure_app` makes. v1 has only `app`: the
    /// app fills the workspace's one screen.
    public enum Kind: String, Sendable, Hashable, Codable {
        case app
    }

    /// `workspace.ensure_app` result value.
    public struct EnsuredApp: Decodable, Sendable, Equatable {
        public var workspaceID: ResourceID
        public var screenID: ResourceID?
        enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id"
            case screenID = "screen_id"
        }
    }

    /// The app's workspace, created on the first call and the same workspace
    /// on every later one (the store keys it by app; any key replays it).
    /// `displayName` is the app's English name; the store names the app's
    /// companion workspace "<displayName> Tabs" for clients (CLI, TUI) that
    /// show the stored name.
    public func ensureApp(_ app: String, kind: Kind = .app, displayName: String? = nil) async throws -> EnsuredApp {
        let key = "cmux-next-app-" + UUID().uuidString.lowercased()
        var params: [String: JSONValue] = ["app": .string(app), "kind": .string(kind.rawValue)]
        if let displayName { params["display_name"] = .string(displayName) }
        let result = try await connection.resourceRequest({ [params] id in
            ResourceRequestEnvelope(id: id, operation: "workspace.ensure_app", params: params, idempotencyKey: key)
        }, as: ResourceMutationResult<EnsuredApp>.self)
        return result.value
    }
}
