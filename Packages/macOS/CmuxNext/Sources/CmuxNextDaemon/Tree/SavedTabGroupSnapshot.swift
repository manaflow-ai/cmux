import Foundation

/// A saved ("pinned") tab group (`saved-tab-groups-v1`): a session-wide
/// record that outlives its placements. Reopening restores the tabs into a
/// pane, reattaching terminals that still run and starting the rest in their
/// saved directories.
///
/// Wire shape (`list-saved-tab-groups`): `{id, name, color, updated_at_ms,
/// members}`. The record does not name its live group; a live group links to
/// it through `TabGroupSnapshot.savedID`. `DaemonTree.savedTabGroups` is
/// filled from `list-saved-tab-groups`, not from `list-workspaces`.
public struct SavedTabGroupSnapshot: Sendable, Hashable, Decodable, Identifiable {
    public var id: SavedTabGroupID
    public var name: String
    public var color: String?
    public var updatedAtMs: UInt64?
    /// Members in order (wire `members`).
    public var tabs: [SavedTab]
    /// The live group linked to this record, if any. Not on the wire;
    /// `DaemonConnection.snapshot()` derives it from `TabGroupSnapshot.savedID`.
    public var openGroup: TabGroupID?

    public init(id: SavedTabGroupID, name: String = "", color: String? = nil, updatedAtMs: UInt64? = nil, tabs: [SavedTab] = [],
                openGroup: TabGroupID? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.updatedAtMs = updatedAtMs
        self.tabs = tabs
        self.openGroup = openGroup
    }

    enum CodingKeys: String, CodingKey {
        case id, name, color, members
        case updatedAtMs = "updated_at_ms"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(SavedTabGroupID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color)
        updatedAtMs = try c.decodeIfPresent(UInt64.self, forKey: .updatedAtMs)
        tabs = try c.decodeIfPresent([SavedTab].self, forKey: .members) ?? []
        openGroup = nil
    }
}

/// One member of a saved group: `{kind:"terminal", terminal_id, cwd, title}`
/// or `{kind:"browser", url, engine, profile_id, title}`.
public struct SavedTab: Sendable, Hashable, Decodable {
    /// `.pty` for wire `"terminal"`, `.browser` for `"browser"`.
    public var kind: TabKind
    public var title: String
    public var cwd: String?
    public var url: String?
    /// Reattached when the terminal still runs.
    public var terminalID: TerminalID?
    /// Frontend browser engine (`"webkit"`/`"cef"`); nil for a CDP browser.
    public var engine: String?
    public var profileID: String?

    public init(kind: TabKind, title: String = "", cwd: String? = nil, url: String? = nil, terminalID: TerminalID? = nil,
                engine: String? = nil, profileID: String? = nil) {
        self.kind = kind
        self.title = title
        self.cwd = cwd
        self.url = url
        self.terminalID = terminalID
        self.engine = engine
        self.profileID = profileID
    }

    enum CodingKeys: String, CodingKey {
        case kind, title, cwd, url, engine
        case terminalID = "terminal_id"
        case profileID = "profile_id"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "terminal"
        kind = rawKind == "terminal" ? .pty : TabKind(rawValue: rawKind)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        terminalID = try c.decodeIfPresent(TerminalID.self, forKey: .terminalID)
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
        profileID = try c.decodeIfPresent(String.self, forKey: .profileID)
    }
}
