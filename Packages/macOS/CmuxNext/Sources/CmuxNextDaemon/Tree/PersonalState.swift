import Foundation

/// The user's personal state, served only by the home session
/// (`list-personal`, `profiles-v1`; plans/cmux-next/data-model.md 1.2c and
/// 3.3): the session registry, rooms with their follows and pins, personal
/// workspace groups, and per-workspace order, group, browser profile and
/// theme. Remote daemons never hold it.
public struct PersonalState: Sendable, Hashable, Decodable {
    public var revision: UInt64
    public var sessions: [SessionRecord]
    /// Rooms (the wire calls them profiles), in order.
    public var profiles: [ProfileSnapshot]
    public var pins: [WorkspacePin]
    public var groups: [WorkspaceGroupSnapshot]
    public var workspaces: [PersonalWorkspace]

    public init(revision: UInt64 = 0, sessions: [SessionRecord] = [], profiles: [ProfileSnapshot] = [], pins: [WorkspacePin] = [],
                groups: [WorkspaceGroupSnapshot] = [], workspaces: [PersonalWorkspace] = []) {
        self.revision = revision
        self.sessions = sessions
        self.profiles = profiles
        self.pins = pins
        self.groups = groups
        self.workspaces = workspaces
    }

    enum CodingKeys: String, CodingKey {
        case sessions, profiles, pins, groups, workspaces
        case revision = "personal_revision"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        sessions = try c.decodeIfPresent([SessionRecord].self, forKey: .sessions) ?? []
        profiles = try c.decodeIfPresent([ProfileSnapshot].self, forKey: .profiles) ?? []
        pins = try c.decodeIfPresent([WorkspacePin].self, forKey: .pins) ?? []
        groups = try c.decodeIfPresent([WorkspaceGroupSnapshot].self, forKey: .groups) ?? []
        workspaces = try c.decodeIfPresent([PersonalWorkspace].self, forKey: .workspaces) ?? []
    }
}

/// One known session (a cmux-tui daemon) in the home session registry.
public struct SessionRecord: Sendable, Hashable, Decodable, Identifiable {
    /// The session's `registry_id`.
    public var id: String
    public var machineName: String?
    public var sessionName: String?
    /// How to reconnect (`{"kind":"local"}`, `{"kind":"cloud","machine":…}`); never secrets.
    public var transport: JSONValue?
    public var lastSeenMs: UInt64?
    public var capabilities: [String]
    /// Its shared groups and order were copied into personal rows.
    public var migrated: Bool

    public init(id: String, machineName: String? = nil, sessionName: String? = nil, transport: JSONValue? = nil,
                lastSeenMs: UInt64? = nil, capabilities: [String] = [], migrated: Bool = false) {
        self.id = id
        self.machineName = machineName
        self.sessionName = sessionName
        self.transport = transport
        self.lastSeenMs = lastSeenMs
        self.capabilities = capabilities
        self.migrated = migrated
    }

    enum CodingKeys: String, CodingKey {
        case transport, capabilities, migrated
        case id = "session_id"
        case machineName = "machine_name"
        case sessionName = "session_name"
        case lastSeenMs = "last_seen_ms"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        machineName = try c.decodeIfPresent(String.self, forKey: .machineName)
        sessionName = try c.decodeIfPresent(String.self, forKey: .sessionName)
        transport = try c.decodeIfPresent(JSONValue.self, forKey: .transport)
        lastSeenMs = try c.decodeIfPresent(UInt64.self, forKey: .lastSeenMs)
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        migrated = try c.decodeIfPresent(Bool.self, forKey: .migrated) ?? false
    }
}
