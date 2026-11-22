import Foundation

// State resources the daemon owns (plans/cmux-next/state-ownership.md 2,
// cmux-tui/spec/resource-api-v2.md "State resources"), as the app reads them
// from `session.events`. Field names follow the v2 catalog
// (cmux-tui/spec/resource-operations-v2.json).

/// One recently closed tab, screen, or workspace (`ClosedItemSnapshot`).
/// The daemon keeps the newest 50; `closed.reopen` recreates one.
public struct ClosedItem: Sendable, Hashable, Identifiable, Decodable {
    public enum Kind: String, Sendable, Hashable, Decodable {
        /// `window`: a window the app closed (`window-records-v1`); it has no member.
        case tab, screen, workspace, window
    }

    /// What reopening recreates for one tab (`ClosedTabRecord`).
    public struct Tab: Sendable, Hashable, Decodable {
        /// `terminal`, `browser`, or `conversation` (closed-conversation-tabs-v1).
        public var kind: String
        public var name: String?
        public var cwd: String?
        public var url: String?
        public var browserProfileID: String?
        public var pinned: Bool
        /// The safe public identity of a closed agent chat; host/install metadata is never exposed.
        public struct AgentSession: Sendable, Hashable, Decodable {
            public var session: String?
            public var harness: String?

            public init(session: String? = nil, harness: String? = nil) {
                self.session = session
                self.harness = harness
            }
        }
        public var agentSession: AgentSession?
        /// The page a closed page tab showed (`page-tabs-v1`); its `url` is then `about:blank`.
        public var page: String?
        /// True when the tab would reopen as nothing: an untouched New Tab page (a chat tab with no
        /// session yet) or a browser on `about:blank`. False from a daemon that does not say.
        public var empty: Bool

        enum CodingKeys: String, CodingKey {
            case kind, name, cwd, url, pinned, agentSession = "agent_session", page, empty
            case browserProfileID = "browser_profile_id"
        }

        public init(kind: String, name: String? = nil, cwd: String? = nil, url: String? = nil,
                    browserProfileID: String? = nil, pinned: Bool = false, empty: Bool = false, agentSession: AgentSession? = nil) {
            self.kind = kind
            self.name = name
            self.cwd = cwd
            self.url = url
            self.browserProfileID = browserProfileID
            self.pinned = pinned
            self.agentSession = agentSession
            self.empty = empty
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(String.self, forKey: .kind)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
            url = try c.decodeIfPresent(String.self, forKey: .url)
            browserProfileID = try c.decodeIfPresent(String.self, forKey: .browserProfileID)
            pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
            agentSession = try c.decodeIfPresent(AgentSession.self, forKey: .agentSession)
            page = try c.decodeIfPresent(String.self, forKey: .page)
            empty = try c.decodeIfPresent(Bool.self, forKey: .empty) ?? false
        }
    }

    /// One screen of the item (`ClosedScreenRecord`); a closed tab has one
    /// screen with one tab.
    public struct Screen: Sendable, Hashable, Decodable {
        public var name: String?
        public var tabs: [Tab]

        public init(name: String? = nil, tabs: [Tab]) {
            self.name = name
            self.tabs = tabs
        }
    }

    /// A deleted personal workspace group (`ClosedWorkspaceGroupRecord`).
    /// Its workspaces stayed open, so the item has no member; reopening it
    /// forms the group again with its id, place and open members.
    public struct Group: Sendable, Hashable, Decodable {
        public var id: String
        public var name: String
        public var color: String?
        /// The group's icon, one emoji or an SF Symbol name
        /// (`workspace-group-icon-v1`); nil for none or an older daemon.
        public var icon: String?

        public init(id: String, name: String, color: String? = nil, icon: String? = nil) {
            self.id = id
            self.name = name
            self.color = color
            self.icon = icon
        }
    }

    /// `closed_…` state id.
    public var id: String
    public var kind: Kind
    /// Tab, screen, or workspace name at close.
    public var name: String?
    /// The workspace a tab or screen was closed from.
    public var workspaceID: ResourceID?
    /// The pane a tab was closed from.
    public var paneID: ResourceID?
    /// Position the item held when it closed.
    public var index: Int
    public var closedAtMs: UInt64
    /// The first member's screens (closed-history-v2 mirrors its first
    /// member at the top level for v1 clients).
    public var screens: [Screen]
    /// Every member's screens, one list per member (`ClosedMemberRecord`);
    /// empty for a v1 item, whose `screens` are the whole item.
    public var memberScreens: [[Screen]]
    /// Every member's name, one per member (a workspace's or screen's name;
    /// nil for a member with none); empty for a v1 item. One close gesture
    /// over several workspaces is one item of several members.
    public var memberNames: [String?]
    /// Set when the item is a deleted personal workspace group.
    public var group: Group?
    /// The window record (`install/window`) the group left, or, for a
    /// `window` item, the closed window itself; nil when no window listed it.
    public var window: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, name, index, screens, members, group, window
        case workspaceID = "workspace_id"
        case paneID = "pane_id"
        case closedAtMs = "closed_at_ms"
    }

    private struct Member: Decodable {
        var screens: [Screen]?
        var name: String?
    }

    public init(id: String, kind: Kind, name: String? = nil, workspaceID: ResourceID? = nil, paneID: ResourceID? = nil,
                index: Int = 0, closedAtMs: UInt64 = 0, screens: [Screen] = [], memberScreens: [[Screen]] = [],
                memberNames: [String?] = [], group: Group? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.index = index
        self.closedAtMs = closedAtMs
        self.screens = screens
        self.memberScreens = memberScreens
        self.memberNames = memberNames
        self.group = group
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        workspaceID = try c.decodeIfPresent(ResourceID.self, forKey: .workspaceID)
        paneID = try c.decodeIfPresent(ResourceID.self, forKey: .paneID)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        closedAtMs = try StateDecimal.decode(c, .closedAtMs) ?? 0
        screens = try c.decodeIfPresent([Screen].self, forKey: .screens) ?? []
        let members = try c.decodeIfPresent([Member].self, forKey: .members) ?? []
        memberScreens = members.map { $0.screens ?? [] }
        memberNames = members.map(\.name)
        group = try c.decodeIfPresent(Group.self, forKey: .group)
        window = try c.decodeIfPresent(String.self, forKey: .window)
    }

    /// Every tab the item would recreate, in order: every member's (one
    /// close gesture of several tabs is one item), else the item's own.
    public var tabs: [Tab] { (memberScreens.isEmpty ? screens : memberScreens.flatMap { $0 }).flatMap(\.tabs) }
}

/// A workspace's status, progress, and newest log line
/// (`WorkspaceStatusSnapshot`), written by hooks and the CLI
/// (`workspace_status.*`, `workspace_progress.*`, `workspace_log.*`).
public struct WorkspaceStatus: Sendable, Hashable, Decodable {
    public struct Entry: Sendable, Hashable, Decodable {
        public var key: String
        public var text: String
        public var icon: String?
        public var color: String?
        /// Loading fields (`cmux status set --state --progress --style`, plans/cmux-next/status-indicators.md
        /// section 5): `busy|success|error|waiting|info`, nil for a plain line (an older daemon or client).
        public var state: String?
        /// 0...1, busy only; nil while indeterminate.
        public var progress: Double?
        /// The reporter's style hint (`arc|native|dot|none`).
        public var style: String?
        /// The terminal the entry is about (`target_terminal`, `term_…`); `cmux status` sets it to
        /// the caller's terminal.
        public var targetTerminal: String?
        /// A finished `cmux status run`'s exit status and how long it ran (success or error only).
        public var exitCode: Int?
        public var durationMs: UInt64?

        enum CodingKeys: String, CodingKey {
            case key, text, icon, color, state, progress, style
            case targetTerminal = "target_terminal"
            case exitCode = "exit_code"
            case durationMs = "duration_ms"
        }

        public init(key: String, text: String, icon: String? = nil, color: String? = nil,
                    state: String? = nil, progress: Double? = nil, style: String? = nil,
                    targetTerminal: String? = nil, exitCode: Int? = nil, durationMs: UInt64? = nil) {
            self.key = key
            self.text = text
            self.icon = icon
            self.color = color
            self.state = state
            self.progress = progress
            self.style = style
            self.targetTerminal = targetTerminal
            self.exitCode = exitCode
            self.durationMs = durationMs
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            text = try c.decode(String.self, forKey: .text)
            icon = try c.decodeIfPresent(String.self, forKey: .icon)
            color = try c.decodeIfPresent(String.self, forKey: .color)
            state = try c.decodeIfPresent(String.self, forKey: .state)
            progress = try c.decodeIfPresent(Double.self, forKey: .progress)
            style = try c.decodeIfPresent(String.self, forKey: .style)
            targetTerminal = try c.decodeIfPresent(String.self, forKey: .targetTerminal)
            exitCode = try? c.decodeIfPresent(Int.self, forKey: .exitCode)
            durationMs = try? StateDecimal.decode(c, .durationMs)
        }
    }

    public struct Progress: Sendable, Hashable, Decodable {
        /// 0...1, nil while indeterminate.
        public var value: Double?
        public var label: String?

        public init(value: Double?, label: String? = nil) {
            self.value = value
            self.label = label
        }
    }

    public struct LogLine: Sendable, Hashable, Decodable {
        /// `info`, `progress`, `success`, `warning`, or `error`.
        public var level: String
        public var source: String?
        public var text: String

        public init(level: String, source: String? = nil, text: String) {
            self.level = level
            self.source = source
            self.text = text
        }
    }

    public var workspaceID: ResourceID
    public var entries: [Entry]
    public var progress: Progress?
    public var logCount: Int
    public var lastLog: LogLine?

    enum CodingKeys: String, CodingKey {
        case entries, progress
        case workspaceID = "workspace_id"
        case logCount = "log_count"
        case lastLog = "last_log"
    }

    public init(workspaceID: ResourceID, entries: [Entry] = [], progress: Progress? = nil, logCount: Int = 0,
                lastLog: LogLine? = nil) {
        self.workspaceID = workspaceID
        self.entries = entries
        self.progress = progress
        self.logCount = logCount
        self.lastLog = lastLog
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try c.decode(ResourceID.self, forKey: .workspaceID)
        entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        progress = try c.decodeIfPresent(Progress.self, forKey: .progress)
        logCount = try c.decodeIfPresent(Int.self, forKey: .logCount) ?? 0
        lastLog = try c.decodeIfPresent(LogLine.self, forKey: .lastLog)
    }

    /// The sidebar's status line: every entry's text in the daemon's order,
    /// joined; nil when there is none.
    public var line: String? {
        let texts = entries.map(\.text).filter { !$0.isEmpty }
        return texts.isEmpty ? nil : texts.joined(separator: " · ")
    }
}

/// A terminal's OSC 9;4 progress as the daemon parses it for every terminal
/// (`TerminalSnapshot.extra.progress`), mounted or not.
public struct TerminalProgressReport: Sendable, Hashable, Decodable {
    public enum State: String, Sendable, Hashable, Decodable {
        case normal, error, indeterminate, paused
    }

    public var state: State
    /// 0...100, nil when the program reported none.
    public var value: Int?

    public init(state: State, value: Int? = nil) {
        self.state = state
        self.value = value
    }
}
