import Foundation

/// One change to a state resource the app mirrors, from a `session.events`
/// delta. A nil payload removes the record.
public enum SessionStateChange: Sendable, Hashable {
    /// A workspace upsert: its ephemeral flag, its agent folder (`extra.agent_folder`), and its
    /// description and manual task status (`extra.description`, `extra.task_status`).
    case workspace(ResourceID, ephemeral: Bool, agentFolder: String?, notes: SessionStateMirror.WorkspaceNotes = .init())
    case workspaceRemoved(ResourceID)
    case screen(ResourceID, SessionStateMirror.ScreenState?)
    case tab(ResourceID, SessionStateMirror.TabRecord?)
    /// A terminal's OSC 9;4 progress, OSC 7501 program status records, running shell command, prompt
    /// and last output.
    case terminal(ResourceID, TerminalProgressReport?, programStatus: [ProgramStatusRecord] = [], busySinceMs: UInt64? = nil,
                  promptSinceMs: UInt64? = nil, lastOutputMs: UInt64? = nil)
    case closed(ClosedItem)
    case closedRemoved(String)
    case status(WorkspaceStatus)
    case statusRemoved(ResourceID)
    /// A workspace's whole checklist (`workspace-checklist-v1`).
    case checklist(WorkspaceChecklist)
    case checklistRemoved(ResourceID)
    case screenGroup(StateScreenGroup)
    case screenGroupRemoved(String)
    /// A stash (`stash-v1`) was stored, changed or removed; readers list the stashes again.
    case stash(String)
    /// The `sidebar_item` / `sidebar_section` changes of one batch, raw
    /// (`sidebar-doc-v1`): the client mirror applies them with the Rust reducer.
    case sidebarBatch(SidebarDocBatch)
}

/// One `session.events` batch of sidebar document changes: the revision it
/// leaves the document at, the idempotency key of the intent that caused it
/// (nil for another client's or the daemon's change) and its changes as sent.
public struct SidebarDocBatch: Sendable, Hashable {
    public var revision: UInt64?
    public var idempotencyKey: String?
    public var changes: [JSONValue]

    public init(revision: UInt64?, idempotencyKey: String?, changes: [JSONValue]) {
        self.revision = revision
        self.idempotencyKey = idempotencyKey
        self.changes = changes
    }

    /// The batch as the mirror's FFI reads it.
    public var json: JSONValue {
        var object: [String: JSONValue] = ["changes": .array(changes)]
        if let revision { object["revision"] = .string(revision.description) }
        if let idempotencyKey { object["idempotency_key"] = .string(idempotencyKey) }
        return .object(object)
    }

    /// `sidebar_doc` is the batch's marker (its revision, previous revision and key).
    static let resources: Set<String> = ["sidebar_item", "sidebar_section", "sidebar_doc"]
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
            var changes = item.changes?.compactMap(\.change) ?? []
            if let batch = item.sidebarBatch { changes.append(.sidebarBatch(batch)) }
            return .delta(changes)
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
        /// The batch's sidebar document changes, kept raw (`sidebar-doc-v1`).
        var sidebarBatch: SidebarDocBatch?

        enum CodingKeys: String, CodingKey {
            case kind, snapshot, changes, revision
            case idempotencyKey = "idempotency_key"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(String.self, forKey: .kind)
            snapshot = try c.decodeIfPresent(Snapshot.self, forKey: .snapshot)
            changes = try c.decodeIfPresent([Lossy<Change>].self, forKey: .changes)
            let raw = (try? c.decodeIfPresent([JSONValue].self, forKey: .changes)) ?? []
            let sidebar = raw.filter { change in
                guard case .object(let object) = change, let resource = object["resource"]?.stringValue else { return false }
                return SidebarDocBatch.resources.contains(resource)
            }
            if !sidebar.isEmpty {
                // The item's `revision` is the session journal's, not the document's: the
                // `sidebar_doc` marker change carries the document revision the mirror reads.
                sidebarBatch = SidebarDocBatch(revision: nil, idempotencyKey: try? c.decodeIfPresent(String.self, forKey: .idempotencyKey),
                                               changes: sidebar)
            }
        }
    }

    /// A workspace, screen, tab, or terminal: its id and `extra` map.
    struct Entity: Decodable {
        var id: ResourceID
        var extra: [String: JSONValue]?

        var ephemeral: Bool { extra?["ephemeral"] == .bool(true) }
        /// The folder new agent chats start in (`workspace.agent_folder.set`).
        var agentFolder: String? { extra?["agent_folder"]?.stringValue }
        /// The description and the manual task status (`workspace.update`); an unknown lane reads as automatic.
        var notes: SessionStateMirror.WorkspaceNotes {
            SessionStateMirror.WorkspaceNotes(description: extra?["description"]?.stringValue,
                                              taskStatus: extra?["task_status"]?.stringValue.flatMap(WorkspaceTaskStatus.init(rawValue:)))
        }

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
            return SessionStateMirror.TabRecord(zoom: zoom, back: urls("back"), forward: urls("forward"),
                                                icon: extra?["icon"]?.stringValue, emulation: extra?["emulation"],
                                                markedUnread: extra?["marked_unread"] == .bool(true),
                                                attention: TabAttention(extra?["attention"]))
        }

        var progress: TerminalProgressReport? {
            guard case .object(let object)? = extra?["progress"],
                  let state = object["state"]?.stringValue.flatMap(TerminalProgressReport.State.init(rawValue:)) else { return nil }
            var value: Int?
            if case .number(let number)? = object["value"] { value = number.saturatedInteger(Int.self) }
            return TerminalProgressReport(state: state, value: value)
        }

        /// OSC 7501 records (`extra.program_status`).
        var programStatus: [ProgramStatusRecord] { ProgramStatusRecord.records(extra) }

        /// When the terminal's running shell command started (`extra.busy.since_ms`, terminal-activity-v1:
        /// OSC 133 C..D), nil at a prompt and while the daemon's `extra.activity` says the command uses
        /// the terminal interactively (`in_use`: htop, vim, a REPL), which is never work in progress.
        var busySinceMs: UInt64? {
            if case .object(let activity)? = extra?["activity"], activity["state"]?.stringValue != "running" { return nil }
            guard case .object(let busy)? = extra?["busy"] else { return nil }
            return busy["since_ms"]?.stringValue.flatMap { UInt64($0, radix: 10) }
        }

        /// Since when the shell sits at its prompt (`extra.prompt.since_ms`: OSC 133 A until C), nil
        /// while a command runs and for a shell without integration.
        var promptSinceMs: UInt64? { ms(extra?["prompt"], "since_ms") }

        /// When the terminal last printed (`extra.last_output.at_ms`); pushed at most every 5 s while
        /// output streams.
        var lastOutputMs: UInt64? { ms(extra?["last_output"], "at_ms") }

        /// The decimal ms string at `key` of `record`.
        private func ms(_ record: JSONValue?, _ key: String) -> UInt64? {
            guard case .object(let object)? = record else { return nil }
            return object[key]?.stringValue.flatMap { UInt64($0, radix: 10) }
        }

        /// The terminal's change as the mirror applies it.
        func terminalChange(_ id: ResourceID) -> SessionStateChange {
            .terminal(id, progress, programStatus: programStatus, busySinceMs: busySinceMs, promptSinceMs: promptSinceMs,
                      lastOutputMs: lastOutputMs)
        }
    }

    struct StateLists: Decodable {
        var closed: [Lossy<ClosedItem>]?
        var workspaceStatus: [Lossy<WorkspaceStatus>]?
        var workspaceChecklists: [Lossy<WorkspaceChecklist>]?
        var screenGroups: [Lossy<StateScreenGroup>]?

        enum CodingKeys: String, CodingKey {
            case closed
            case workspaceStatus = "workspace_status"
            case workspaceChecklists = "workspace_checklist"
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
                if !workspace.notes.isEmpty { mirror.workspaceNotes[workspace.id] = workspace.notes }
            }
            for screen in screens?.compactMap(\.value) ?? [] { mirror.screens.updateValue(screen.screenState, forKey: screen.id) }
            for tab in tabs?.compactMap(\.value) ?? [] where !tab.tabRecord.isEmpty { mirror.tabs.updateValue(tab.tabRecord, forKey: tab.id) }
            for terminal in terminals?.compactMap(\.value) ?? [] {
                mirror.apply(terminal.terminalChange(terminal.id))
            }
            mirror.closed = Array((state.closed?.compactMap(\.value) ?? []).prefix(SessionStateMirror.closedLimit))
            for status in state.workspaceStatus?.compactMap(\.value) ?? [] { mirror.workspaceStatus.updateValue(status, forKey: status.workspaceID) }
            for checklist in state.workspaceChecklists?.compactMap(\.value) ?? [] where !checklist.items.isEmpty {
                mirror.workspaceChecklists.updateValue(checklist, forKey: checklist.workspaceID)
            }
            for group in state.screenGroups?.compactMap(\.value) ?? [] { mirror.screenGroups.updateValue(group, forKey: group.id) }
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
                change = .workspace(rid, ephemeral: workspace.ephemeral, agentFolder: workspace.agentFolder, notes: workspace.notes)
            case ("delete", "workspace"): change = .workspaceRemoved(rid)
            case ("upsert", "screen"): change = .screen(rid, try c.decode(Entity.self, forKey: .value).screenState)
            case ("delete", "screen"): change = .screen(rid, nil)
            case ("upsert", "tab"): change = .tab(rid, try c.decode(Entity.self, forKey: .value).tabRecord)
            case ("delete", "tab"): change = .tab(rid, nil)
            case ("upsert", "terminal"):
                change = try c.decode(Entity.self, forKey: .value).terminalChange(rid)
            case ("delete", "terminal"): change = .terminal(rid, nil)
            case ("state_upsert", "closed"): change = .closed(try c.decode(ClosedItem.self, forKey: .value))
            case ("state_delete", "closed"): change = .closedRemoved(id)
            case ("state_upsert", "workspace_status"): change = .status(try c.decode(WorkspaceStatus.self, forKey: .value))
            case ("state_delete", "workspace_status"): change = .statusRemoved(rid)
            case ("state_upsert", "workspace_checklist"): change = .checklist(try c.decode(WorkspaceChecklist.self, forKey: .value))
            case ("state_delete", "workspace_checklist"): change = .checklistRemoved(rid)
            case ("state_upsert", "screen_group"): change = .screenGroup(try c.decode(StateScreenGroup.self, forKey: .value))
            case ("state_delete", "screen_group"): change = .screenGroupRemoved(id)
            case ("state_upsert", "stash"), ("state_delete", "stash"): change = .stash(id)
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
