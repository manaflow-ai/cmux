import Foundation

/// One change to a state resource the app mirrors, from a `session.events`
/// delta. A nil payload removes the record.
public enum SessionStateChange: Sendable, Hashable {
    /// A workspace upsert: its ephemeral flag and its agent folder (`extra.agent_folder`).
    case workspace(ResourceID, ephemeral: Bool, agentFolder: String?)
    case workspaceRemoved(ResourceID)
    case screen(ResourceID, SessionStateMirror.ScreenState?)
    case tab(ResourceID, SessionStateMirror.TabRecord?)
    case terminal(ResourceID, TerminalProgressReport?)
    case closed(ClosedItem)
    case closedRemoved(String)
    case status(WorkspaceStatus)
    case statusRemoved(ResourceID)
    case screenGroup(StateScreenGroup)
    case screenGroupRemoved(String)
}

/// A `session.events` stream line, decoded for the state the app mirrors.
public enum SessionStreamItem: Sendable, Hashable {
    /// The full state: replaces the mirror.
    case snapshot(SessionStateMirror)
    case delta([SessionStateChange])
    /// The stream ended (`stream_end`), e.g. `gap` after the app fell behind.
    case ended(reason: String)

    /// The stream needs the connection's attention: cancel or reopen it.
    var endsStream: Bool {
        switch self {
        case .ended: true
        case .snapshot, .delta: false
        }
    }

    /// Decodes one `stream_item` or `stream_end` line.
    static func decode(_ line: Data) -> SessionStreamItem? {
        guard let envelope = try? JSONDecoder().decode(SessionWire.Envelope.self, from: line) else { return nil }
        if envelope.type == "stream_end" { return .ended(reason: envelope.reason ?? "ended") }
        guard let item = envelope.item else { return nil }
        switch item.kind {
        case "snapshot":
            guard let snapshot = item.snapshot else { return nil }
            guard let state = snapshot.extra?.state else { return nil }
            return .snapshot(snapshot.mirror(state))
        case "delta":
            return .delta(item.changes?.compactMap(\.change) ?? [])
        default:
            return nil
        }
    }
}

/// Wire shapes of `session.events` (cmux-tui/spec/resource-operations-v2.json:
/// `SessionEventItem`, `ResourceSnapshot`, `ResourceChange`). Only the
/// fields the mirror needs are decoded; everything else is skipped.
enum SessionWire {
    struct Envelope: Decodable {
        var type: String
        var reason: String?
        var item: Item?
    }

    struct Item: Decodable {
        var kind: String
        var snapshot: Snapshot?
        var changes: [Lossy<Change>]?
    }

    /// A workspace, screen, tab, or terminal: its id and `extra` map.
    struct Entity: Decodable {
        var id: ResourceID
        var extra: [String: JSONValue]?

        var ephemeral: Bool { extra?["ephemeral"] == .bool(true) }
        /// The folder new agent chats start in (`workspace.agent_folder.set`).
        var agentFolder: String? { extra?["agent_folder"]?.stringValue }

        var screenState: SessionStateMirror.ScreenState {
            SessionStateMirror.ScreenState(pinned: extra?["pinned"] == .bool(true), color: extra?["color"]?.stringValue,
                                           icon: extra?["icon"]?.stringValue, group: extra?["screen_group_id"]?.stringValue)
        }

        var tabRecord: SessionStateMirror.TabRecord {
            func urls(_ key: String) -> [String] {
                guard case .array(let values)? = extra?[key] else { return [] }
                return values.compactMap(\.stringValue)
            }
            var zoom: Double?
            if case .number(let value)? = extra?["zoom"] { zoom = value }
            return SessionStateMirror.TabRecord(zoom: zoom, back: urls("back"), forward: urls("forward"))
        }

        var progress: TerminalProgressReport? {
            guard case .object(let object)? = extra?["progress"],
                  let state = object["state"]?.stringValue.flatMap(TerminalProgressReport.State.init(rawValue:)) else { return nil }
            var value: Int?
            if case .number(let number)? = object["value"] { value = Int(number) }
            return TerminalProgressReport(state: state, value: value)
        }
    }

    struct StateLists: Decodable {
        var closed: [Lossy<ClosedItem>]?
        var workspaceStatus: [Lossy<WorkspaceStatus>]?
        var screenGroups: [Lossy<StateScreenGroup>]?

        enum CodingKeys: String, CodingKey {
            case closed
            case workspaceStatus = "workspace_status"
            case screenGroups = "screen_groups"
        }
    }

    struct SnapshotExtra: Decodable {
        var state: StateLists?
    }

    struct Snapshot: Decodable {
        var workspaces: [Lossy<Entity>]?
        var screens: [Lossy<Entity>]?
        var tabs: [Lossy<Entity>]?
        var terminals: [Lossy<Entity>]?
        var extra: SnapshotExtra?

        func mirror(_ state: StateLists) -> SessionStateMirror {
            var mirror = SessionStateMirror()
            for workspace in workspaces?.compactMap(\.value) ?? [] {
                if workspace.ephemeral { mirror.ephemeralWorkspaces.insert(workspace.id) }
                if let folder = workspace.agentFolder { mirror.agentFolders[workspace.id] = folder }
            }
            for screen in screens?.compactMap(\.value) ?? [] { mirror.screens[screen.id] = screen.screenState }
            for tab in tabs?.compactMap(\.value) ?? [] where !tab.tabRecord.isEmpty { mirror.tabs[tab.id] = tab.tabRecord }
            for terminal in terminals?.compactMap(\.value) ?? [] { mirror.terminalProgress[terminal.id] = terminal.progress }
            mirror.closed = Array((state.closed?.compactMap(\.value) ?? []).prefix(SessionStateMirror.closedLimit))
            for status in state.workspaceStatus?.compactMap(\.value) ?? [] { mirror.workspaceStatus[status.workspaceID] = status }
            for group in state.screenGroups?.compactMap(\.value) ?? [] { mirror.screenGroups[group.id] = group }
            return mirror
        }
    }

    /// One `ResourceChange`; `change` is nil for resources the mirror does not keep.
    struct Change: Decodable {
        var change: SessionStateChange?

        enum CodingKeys: String, CodingKey { case kind, resource, id, value }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try c.decode(String.self, forKey: .kind)
            let resource = try c.decode(String.self, forKey: .resource)
            let id = try c.decode(String.self, forKey: .id)
            let rid = ResourceID(rawValue: id)
            switch (kind, resource) {
            case ("upsert", "workspace"):
                let workspace = try c.decode(Entity.self, forKey: .value)
                change = .workspace(rid, ephemeral: workspace.ephemeral, agentFolder: workspace.agentFolder)
            case ("delete", "workspace"): change = .workspaceRemoved(rid)
            case ("upsert", "screen"): change = .screen(rid, try c.decode(Entity.self, forKey: .value).screenState)
            case ("delete", "screen"): change = .screen(rid, nil)
            case ("upsert", "tab"): change = .tab(rid, try c.decode(Entity.self, forKey: .value).tabRecord)
            case ("delete", "tab"): change = .tab(rid, nil)
            case ("upsert", "terminal"): change = .terminal(rid, try c.decode(Entity.self, forKey: .value).progress)
            case ("delete", "terminal"): change = .terminal(rid, nil)
            case ("state_upsert", "closed"): change = .closed(try c.decode(ClosedItem.self, forKey: .value))
            case ("state_delete", "closed"): change = .closedRemoved(id)
            case ("state_upsert", "workspace_status"): change = .status(try c.decode(WorkspaceStatus.self, forKey: .value))
            case ("state_delete", "workspace_status"): change = .statusRemoved(rid)
            case ("state_upsert", "screen_group"): change = .screenGroup(try c.decode(StateScreenGroup.self, forKey: .value))
            case ("state_delete", "screen_group"): change = .screenGroupRemoved(id)
            default: change = nil
            }
        }
    }

    /// Decodes an element or skips it, so one malformed record never drops the rest.
    struct Lossy<T: Decodable>: Decodable {
        var value: T?

        init(from decoder: any Decoder) throws {
            value = try? T(from: decoder)
        }
    }
}

extension SessionWire.Lossy where T == SessionWire.Change {
    var change: SessionStateChange? { value?.change }
}
