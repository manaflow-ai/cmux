import Foundation

/// A saved ("pinned") tab group: a session-wide record that outlives its
/// placements. Closing the open group keeps the record; opening it restores
/// the tabs into any pane, reattaching terminals that still run and starting
/// new ones in the saved cwd otherwise.
///
/// TODO(feat-cmux-next-daemon): proposed `Tree.saved_tab_groups[]` of
/// `{id, name, color, tabs, open_group}` (plans/cmux-next/architecture.md
/// section 7). Wire names are guesses until that branch serves them.
public struct SavedTabGroupSnapshot: Sendable, Hashable, Decodable, Identifiable {
    public var id: SavedTabGroupID
    public var name: String
    public var color: String?
    public var tabs: [SavedTab]
    /// The live group this record is open as, if any.
    public var openGroup: TabGroupID?

    public init(id: SavedTabGroupID, name: String = "", color: String? = nil, tabs: [SavedTab] = [], openGroup: TabGroupID? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.tabs = tabs
        self.openGroup = openGroup
    }

    enum CodingKeys: String, CodingKey {
        case id, name, color, tabs
        case openGroup = "open_group"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(SavedTabGroupID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color)
        tabs = try c.decodeIfPresent([SavedTab].self, forKey: .tabs) ?? []
        openGroup = try c.decodeIfPresent(TabGroupID.self, forKey: .openGroup)
    }
}

/// One tab of a saved group: enough to restore it.
public struct SavedTab: Sendable, Hashable, Decodable {
    public var kind: TabKind
    public var title: String
    public var cwd: String?
    public var url: String?
    /// Reattached when the terminal still runs.
    public var terminalID: TerminalID?

    enum CodingKeys: String, CodingKey {
        case kind, title, cwd, url
        case terminalID = "terminal_id"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(TabKind.self, forKey: .kind) ?? .pty
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        terminalID = try c.decodeIfPresent(TerminalID.self, forKey: .terminalID)
    }
}
