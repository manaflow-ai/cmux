import CmuxNextIPC
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
    /// The idempotency key for the next state mutation. The daemon echoes it as the deltas'
    /// `mutation_id`, so a caused scope records it on `connection` (``MutationCauseLedger``).
    static func stateKey(on connection: DaemonConnection) -> String {
        let scope = DaemonCommandScope.current
        let key = "cmux-next-" + (scope?.nextMutationID() ?? UUID().uuidString.lowercased())
        scope?.recordMutation(key, in: connection.mutationCauses)
        return key
    }

    /// Sends generated state mutation `request` and returns its `value`.
    @discardableResult
    func stateMutation<Request: ResourceMutationRequest, R: Decodable & Sendable>(
        _ request: Request, as type: R.Type = JSONValue.self
    ) async throws -> R {
        try await ResourceOperationClient(connection: connection)
            .mutate(request, idempotencyKey: Self.stateKey(on: connection), as: ResourceMutationResult<R>.self).value
    }

    /// Sends generated read `request` and decodes its `result` as `type`.
    func stateRead<Request: ResourceUnkeyedRequest, R: Decodable & Sendable>(
        _ request: Request, as type: R.Type = JSONValue.self
    ) async throws -> R {
        try await ResourceOperationClient(connection: connection).read(request, as: type)
    }

    /// The selector of resource `id`.
    static func selector(_ id: ResourceID) -> ResourceSelector { ResourceSelector(rawValue: id.rawValue) }

    /// An index param: negative is 0, as the hand-built params sent `max(0, index)`.
    static func index(_ index: Int) -> UInt32 { UInt32(clamping: index) }

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
        try await stateMutation(V2ClosedReopenRequest(closed: id), as: ReopenedItem.self)
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
        try await stateMutation(Self.reopenRequest(tab: tab, fallbackPane: fallbackPane), as: ReopenedItem.self)
    }

    /// The `closed.reopen {tab, fallback_pane?}` request.
    static func reopenRequest(tab: String, fallbackPane: String?) -> V2ClosedReopenRequest {
        V2ClosedReopenRequest(fallbackPane: fallbackPane.map { V2PaneID(rawValue: $0) }, tab: V2TabID(rawValue: tab))
    }

    /// The window ids of install `installID`'s window records (`window_record.list`).
    public func windowRecordIDs(installID: String) async throws -> [String] {
        let list = try await ResourceOperationClient(connection: connection)
            .read(V2WindowRecordListRequest(), as: JSONValue.self)
        return (list.arrayValue ?? []).compactMap { record in
            record["install_id"]?.stringValue == installID ? record["window_id"]?.stringValue : nil
        }
    }

    /// Puts this install's record of window `windowID` (`window_record.put`,
    /// single writer per record, so no revision precondition).
    public func putWindowRecord(installID: String, windowID: String, record: JSONValue) async throws {
        try await stateMutation(V2WindowRecordPutRequest(installID: installID, record: ResourceJSON(record), windowID: windowID))
    }

    /// Deletes this install's record of window `windowID` (`window_record.delete`).
    public func deleteWindowRecord(installID: String, windowID: String) async throws {
        try await stateMutation(V2WindowRecordDeleteRequest(installID: installID, windowID: windowID))
    }

    /// Deletes closed group `id` for good (Delete Permanently, `closed.delete`):
    /// it cannot be reopened, and its terminal archives go with it.
    public func deleteClosed(_ id: String) async throws {
        try await stateMutation(V2ClosedDeleteRequest(closed: id))
    }

    /// Deletes every closed group, or every group closed at or after
    /// `sinceMs` (Clear Recently Closed, `closed.delete {all}`).
    public func deleteAllClosed(sinceMs: UInt64?) async throws {
        try await stateMutation(V2ClosedDeleteRequest(all: true, sinceMs: sinceMs.map { String($0) }))
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
        let request = Self.workspaceCreateRequest(name: name, ephemeral: ephemeral, terminal: terminal,
                                                  focus: focus, daemonSupportsFocus: supportsFocus)
        return try await stateMutation(request, as: CreatedWorkspace.self)
    }

    /// The `workspace.create` request. `focus` is sent only to a daemon with
    /// `workspace-create-focus-v1`: an older one refuses the field and
    /// focuses every new workspace anyway.
    static func workspaceCreateRequest(name: String?, ephemeral: Bool, terminal: Bool,
                                       focus: Bool, daemonSupportsFocus: Bool) -> V2WorkspaceCreateRequest {
        V2WorkspaceCreateRequest(ephemeral: ephemeral ? true : nil, focus: focus && daemonSupportsFocus ? true : nil,
                                 initialContent: terminal ? .terminal : .empty, name: name)
    }

    /// Workspace title, color, icon, description (`workspace-description-v1`) and manual task
    /// status (`workspace-status-v1`; `.clear` is automatic) through `workspace.update`. The
    /// caller checks the description and status capabilities; an older daemon refuses those fields.
    public func updateWorkspace(_ workspace: ResourceID, title: FieldUpdate<String> = .unchanged,
                                color: FieldUpdate<String> = .unchanged, icon: FieldUpdate<String> = .unchanged,
                                description: FieldUpdate<String> = .unchanged,
                                taskStatus: FieldUpdate<WorkspaceTaskStatus> = .unchanged) async throws {
        try await stateMutation(Self.workspaceUpdateRequest(workspace, title: title, color: color, icon: icon,
                                                            description: description, taskStatus: taskStatus))
    }

    /// The `workspace.update` request: an `.unchanged` field is left out, `.clear` sends `null`.
    static func workspaceUpdateRequest(_ workspace: ResourceID, title: FieldUpdate<String>, color: FieldUpdate<String>,
                                       icon: FieldUpdate<String>, description: FieldUpdate<String>,
                                       taskStatus: FieldUpdate<WorkspaceTaskStatus>) -> V2WorkspaceUpdateRequest {
        V2WorkspaceUpdateRequest(
            workspace: selector(workspace), color: color.resourceField { $0 }, description: description.resourceField { $0 },
            icon: icon.resourceField { $0 },
            taskStatus: taskStatus.resourceField { V2WorkspaceUpdateRequest.TaskStatus(rawValue: $0.rawValue) },
            title: title.resourceField { $0 })
    }

    /// The folder new agent chats of the workspace start in (`workspace.agent_folder.set`); nil
    /// clears it. The daemon takes it only from the verified app (origin `user`) and only as an
    /// absolute, existing, canonical folder.
    public func setAgentFolder(_ workspace: ResourceID, path: String?) async throws {
        try await stateMutation(V2WorkspaceAgentFolderSetRequest(workspace: Self.selector(workspace), path: path))
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
        if pinned {
            try await stateMutation(V2TabPinRequest(tab: Self.selector(tab)))
        } else {
            try await stateMutation(V2TabUnpinRequest(tab: Self.selector(tab)))
        }
    }

    /// The tab record's zoom, user icon and a browser tab's back/forward lists (`tab.update`).
    public func updateTabRecord(_ tab: ResourceID, zoom: FieldUpdate<Double> = .unchanged, icon: FieldUpdate<String> = .unchanged,
                                back: [String]? = nil, forward: [String]? = nil, markedUnread: Bool? = nil) async throws {
        try await stateMutation(Self.tabRecordUpdateRequest(tab, zoom: zoom, icon: icon, back: back, forward: forward,
                                                            markedUnread: markedUnread))
    }

    /// The `tab.update` request: at most the newest 20 back and the nearest 20 forward URLs.
    /// `markedUnread` is tab-mark-unread-v1: the caller checks the capability; an older daemon
    /// refuses the field.
    static func tabRecordUpdateRequest(_ tab: ResourceID, zoom: FieldUpdate<Double>, icon: FieldUpdate<String>,
                                       back: [String]?, forward: [String]?, markedUnread: Bool?) -> V2TabUpdateRequest {
        V2TabUpdateRequest(tab: selector(tab), back: back.map { Array($0.suffix(20)) },
                           forward: forward.map { Array($0.prefix(20)) }, icon: icon.resourceField { $0 },
                           markedUnread: markedUnread, zoom: zoom.resourceField { $0 })
    }
}
