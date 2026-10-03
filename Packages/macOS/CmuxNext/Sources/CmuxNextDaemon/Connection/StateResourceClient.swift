import Foundation

/// The daemon's state resources over `cmux.protocol/2`
/// (cmux-tui/spec/resource-api-v2.md "State resources"), the workspace-store
/// side of the daemon (OWNERSHIP-PRINCIPLES.md): closed history, workspaces,
/// tab records, tab groups, screen metadata and groups, personal workspace
/// groups. `DaemonConnection.state`. Callers check
/// `DaemonStore.servesStateResources` first; a daemon that predates them
/// rejects these with `validation.invalid`. Its own type, not a
/// `DaemonConnection` extension (that type's line budget is frozen).
///
/// Every mutation carries an idempotency key. Inside an app action with a
/// key (`DaemonCommandScope`) it derives from that key and the mutation's
/// ordinal, like the raw `mutation_id`, so a retried action replays.
public struct StateResourceClient: Sendable {
    public let connection: DaemonConnection

    public init(connection: DaemonConnection) {
        self.connection = connection
    }
}

extension DaemonConnection {
    /// The v2 state operations on this connection.
    public nonisolated var state: StateResourceClient { StateResourceClient(connection: self) }
}

extension StateResourceClient {
    /// The idempotency key for the next state mutation.
    static func stateKey() -> String {
        "cmux-next-" + (DaemonCommandScope.current?.nextMutationID() ?? UUID().uuidString.lowercased())
    }

    /// Sends one state mutation and returns its `value`.
    @discardableResult
    func stateMutation<R: Decodable & Sendable>(_ operation: String, _ params: [String: JSONValue],
                                                 as type: R.Type = JSONValue.self) async throws -> R {
        let key = Self.stateKey()
        return try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: operation, params: params, idempotencyKey: key)
        }, as: ResourceMutationResult<R>.self).value
    }

    static func ids(_ ids: [ResourceID]) -> JSONValue { .array(ids.map { .string($0.rawValue) }) }

    static func field<V>(_ update: FieldUpdate<V>, into params: inout [String: JSONValue], _ key: String,
                         _ value: (V) -> JSONValue) {
        switch update {
        case .unchanged: break
        case .clear: params[key] = .null
        case .set(let new): params[key] = value(new)
        }
    }

    // MARK: Closed history

    /// What `closed.reopen` recreated.
    public struct ReopenedItem: Decodable, Sendable, Equatable {
        public var workspaceID: ResourceID
        public var screenIDs: [ResourceID]
        public var tabIDs: [ResourceID]

        enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id"
            case screenIDs = "screen_ids"
            case tabIDs = "tab_ids"
        }
    }

    /// Reopens closed item `id` (`closed_…`) where it was, and removes it
    /// from the history.
    @discardableResult
    public func reopenClosed(_ id: String) async throws -> ReopenedItem {
        try await stateMutation("closed.reopen", ["closed": .string(id)], as: ReopenedItem.self)
    }

    // MARK: Workspaces

    /// What `workspace.create` made (`CreatedPath`).
    public struct CreatedWorkspace: Decodable, Sendable, Equatable {
        public var workspaceID: ResourceID
        public var tabID: ResourceID?
        public var terminalID: ResourceID?

        enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id"
            case tabID = "tab_id"
            case terminalID = "terminal_id"
        }
    }

    /// `workspace.create`; `ephemeral` workspaces are closed by the daemon at
    /// its next start and leave no closed history.
    @discardableResult
    public func createWorkspace(name: String?, ephemeral: Bool, terminal: Bool) async throws -> CreatedWorkspace {
        var params: [String: JSONValue] = ["initial_content": .string(terminal ? "terminal" : "empty")]
        if let name { params["name"] = .string(name) }
        if ephemeral { params["ephemeral"] = .bool(true) }
        return try await stateMutation("workspace.create", params, as: CreatedWorkspace.self)
    }

    /// Workspace title, color, and icon (`workspace.update`).
    public func updateWorkspace(_ workspace: ResourceID, title: FieldUpdate<String> = .unchanged,
                                color: FieldUpdate<String> = .unchanged, icon: FieldUpdate<String> = .unchanged) async throws {
        var params: [String: JSONValue] = ["workspace": .string(workspace.rawValue)]
        Self.field(title, into: &params, "title") { .string($0) }
        Self.field(color, into: &params, "color") { .string($0) }
        Self.field(icon, into: &params, "icon") { .string($0) }
        try await stateMutation("workspace.update", params)
    }

    /// Workspace identity through `workspace.update` when `resource` (the
    /// workspace's public id on a daemon with state resources) is given,
    /// else the raw `set-workspace-metadata`.
    public func setWorkspaceIdentity(_ key: WorkspaceKey, resource: ResourceID?, title: FieldUpdate<String> = .unchanged,
                                     color: FieldUpdate<String> = .unchanged, icon: FieldUpdate<String> = .unchanged) async throws {
        if let resource { return try await updateWorkspace(resource, title: title, color: color, icon: icon) }
        _ = try await connection.setWorkspaceMetadata(key, color: color, icon: icon, title: title)
    }

    // MARK: Tabs

    /// `tab.pin` / `tab.unpin`: pinned tabs sort first and leave any group.
    public func setTabPinned(_ tab: ResourceID, _ pinned: Bool) async throws {
        try await stateMutation(pinned ? "tab.pin" : "tab.unpin", ["tab": .string(tab.rawValue)])
    }

    /// The tab record's zoom and a browser tab's back/forward lists (`tab.update`).
    public func updateTabRecord(_ tab: ResourceID, zoom: FieldUpdate<Double> = .unchanged, back: [String]? = nil,
                                forward: [String]? = nil) async throws {
        var params: [String: JSONValue] = ["tab": .string(tab.rawValue)]
        Self.field(zoom, into: &params, "zoom") { .number($0) }
        if let back { params["back"] = .array(back.suffix(20).map { .string($0) }) }
        if let forward { params["forward"] = .array(forward.prefix(20).map { .string($0) }) }
        try await stateMutation("tab.update", params)
    }
}
