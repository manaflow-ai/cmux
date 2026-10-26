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
        /// Nil when the reply names no workspace (a reopen of a deleted
        /// space that had none may; cmux-tui-core names the active one).
        public var workspaceID: ResourceID?
        public var screenIDs: [ResourceID]
        public var tabIDs: [ResourceID]
        /// For a reopened `window` group: the window record (`install/window`) to show again.
        public var window: String?

        enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id"
            case screenIDs = "screen_ids"
            case tabIDs = "tab_ids"
            case window
        }
    }

    /// Reopens closed item `id` (`closed_…`) where it was, and removes it
    /// from the history.
    @discardableResult
    public func reopenClosed(_ id: String) async throws -> ReopenedItem {
        try await stateMutation("closed.reopen", ["closed": .string(id)], as: ReopenedItem.self)
    }

    /// Reopens closed tab `tab` (`tab_…`) by its id, under that same id
    /// (`closed.reopen {tab}`, a `cmux://tab/` link to a closed tab): the
    /// member of the newest closed group that holds it.
    ///
    /// - Parameters:
    ///   - tab: The tab's resource id.
    ///   - fallbackPane: The `pane_` id the tab opens in when its own pane
    ///     and workspace are gone; nil for the session's focused pane.
    /// - Throws: `DaemonError.command` with code `resource.not_found` when
    ///   no closed group holds the tab (it is open, or its record is gone).
    @discardableResult
    public func reopenClosed(tab: String, fallbackPane: String?) async throws -> ReopenedItem {
        var params: [String: JSONValue] = ["tab": .string(tab)]
        if let fallbackPane { params["fallback_pane"] = .string(fallbackPane) }
        return try await stateMutation("closed.reopen", params, as: ReopenedItem.self)
    }

    /// Reopens closed workspace `workspace` (`ws_…`) by the id it had
    /// (`closed.reopen {workspace}`, a `cmux://workspace/` link to a closed
    /// workspace): the workspace member of the newest closed group that
    /// recorded it. It reopens as a new workspace (the reply's `workspaceID`).
    ///
    /// - Throws: `DaemonError.command` with code `resource.not_found` when
    ///   no closed group holds the workspace (it is open, or its record is gone).
    @discardableResult
    public func reopenClosed(workspace: String) async throws -> ReopenedItem {
        try await stateMutation("closed.reopen", ["workspace": .string(workspace)], as: ReopenedItem.self)
    }

    /// The window ids of install `installID`'s window records (`window_record.list`).
    public func windowRecordIDs(installID: String) async throws -> [String] {
        let list = try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "window_record.list", params: [:], idempotencyKey: nil)
        }, as: JSONValue.self)
        return (list.arrayValue ?? []).compactMap { record in
            record["install_id"]?.stringValue == installID ? record["window_id"]?.stringValue : nil
        }
    }

    /// Puts this install's record of window `windowID` (`window_record.put`,
    /// single writer per record, so no revision precondition).
    public func putWindowRecord(installID: String, windowID: String, record: JSONValue) async throws {
        try await stateMutation("window_record.put", ["install_id": .string(installID), "window_id": .string(windowID),
                                                      "record": record])
    }

    /// Deletes this install's record of window `windowID` (`window_record.delete`).
    public func deleteWindowRecord(installID: String, windowID: String) async throws {
        try await stateMutation("window_record.delete", ["install_id": .string(installID), "window_id": .string(windowID)])
    }

    /// Deletes closed group `id` for good (Delete Permanently, `closed.delete`):
    /// it cannot be reopened, and its terminal archives go with it.
    public func deleteClosed(_ id: String) async throws {
        try await stateMutation("closed.delete", ["closed": .string(id)])
    }

    /// Deletes every closed group, or every group closed at or after
    /// `sinceMs` (Clear Recently Closed, `closed.delete {all}`).
    public func deleteAllClosed(sinceMs: UInt64?) async throws {
        var params: [String: JSONValue] = ["all": .bool(true)]
        if let sinceMs { params["since_ms"] = .string(String(sinceMs)) }
        try await stateMutation("closed.delete", params)
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
    /// its next start and leave no closed history. `focus` makes the new
    /// workspace the daemon's focused one, as the person's own creations
    /// are; without it the daemon keeps its focused workspace.
    @discardableResult
    public func createWorkspace(name: String?, ephemeral: Bool, terminal: Bool, focus: Bool) async throws -> CreatedWorkspace {
        let supportsFocus = await connection.identity?.supports(DaemonCapability.workspaceCreateFocus.rawValue) == true
        let params: [String: JSONValue] = Self.workspaceCreateParams(name: name, ephemeral: ephemeral, terminal: terminal,
                                                                     focus: focus, daemonSupportsFocus: supportsFocus)
        return try await stateMutation("workspace.create", params, as: CreatedWorkspace.self)
    }

    /// The `workspace.create` params. `focus` is sent only to a daemon with
    /// `workspace-create-focus-v1`: an older one refuses the field and
    /// focuses every new workspace anyway.
    static func workspaceCreateParams(name: String?, ephemeral: Bool, terminal: Bool,
                                      focus: Bool, daemonSupportsFocus: Bool) -> [String: JSONValue] {
        var params: [String: JSONValue] = ["initial_content": .string(terminal ? "terminal" : "empty")]
        if let name { params["name"] = .string(name) }
        if ephemeral { params["ephemeral"] = .bool(true) }
        if focus, daemonSupportsFocus { params["focus"] = .bool(true) }
        return params
    }

    /// Workspace title, color, icon, description (`workspace-description-v1`) and manual task
    /// status (`workspace-status-v1`; `.clear` is automatic) through `workspace.update`. The
    /// caller checks the description and status capabilities; an older daemon refuses those fields.
    public func updateWorkspace(_ workspace: ResourceID, title: FieldUpdate<String> = .unchanged,
                                color: FieldUpdate<String> = .unchanged, icon: FieldUpdate<String> = .unchanged,
                                description: FieldUpdate<String> = .unchanged,
                                taskStatus: FieldUpdate<WorkspaceTaskStatus> = .unchanged) async throws {
        var params: [String: JSONValue] = ["workspace": .string(workspace.rawValue)]
        Self.field(title, into: &params, "title") { .string($0) }
        Self.field(color, into: &params, "color") { .string($0) }
        Self.field(icon, into: &params, "icon") { .string($0) }
        Self.field(description, into: &params, "description") { .string($0) }
        Self.field(taskStatus, into: &params, "task_status") { .string($0.rawValue) }
        try await stateMutation("workspace.update", params)
    }

    /// The folder new agent chats of the workspace start in (`workspace.agent_folder.set`); nil
    /// clears it. The daemon takes it only from the verified app (origin `user`) and only as an
    /// absolute, existing, canonical folder.
    public func setAgentFolder(_ workspace: ResourceID, path: String?) async throws {
        let params: [String: JSONValue] = ["workspace": .string(workspace.rawValue), "path": path.map(JSONValue.string) ?? .null]
        try await stateMutation("workspace.agent_folder.set", params)
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

    /// The tab record's zoom, user icon and a browser tab's back/forward lists (`tab.update`).
    public func updateTabRecord(_ tab: ResourceID, zoom: FieldUpdate<Double> = .unchanged, icon: FieldUpdate<String> = .unchanged,
                                back: [String]? = nil, forward: [String]? = nil, markedUnread: Bool? = nil) async throws {
        var params: [String: JSONValue] = ["tab": .string(tab.rawValue)]
        // tab-mark-unread-v1: the caller checks the capability; an older daemon refuses the field.
        if let markedUnread { params["marked_unread"] = .bool(markedUnread) }
        Self.field(zoom, into: &params, "zoom") { .number($0) }
        Self.field(icon, into: &params, "icon") { .string($0) }
        if let back { params["back"] = .array(back.suffix(20).map { .string($0) }) }
        if let forward { params["forward"] = .array(forward.prefix(20).map { .string($0) }) }
        try await stateMutation("tab.update", params)
    }
}
