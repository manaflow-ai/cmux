import Foundation

/// The personal window-state document.
public struct WindowStateDocument: Codable, Sendable, Hashable {
    public static let schemaVersion: UInt32 = 1
    public var windows: [WindowRecord]
    /// Sidebar group collapse state (group key -> collapsed).
    public var collapsedGroups: [String: Bool]
    /// The agent chat tabs each pane lists (pane key -> tabs, in strip order). cmux-tui has no agent
    /// tab kind yet, so the app records them here; acpmux keeps their sessions (R138).
    public var agentTabs: [String: [AgentTabRecord]]

    public init(windows: [WindowRecord] = [], collapsedGroups: [String: Bool] = [:],
                agentTabs: [String: [AgentTabRecord]] = [:]) {
        self.windows = windows
        self.collapsedGroups = collapsedGroups
        self.agentTabs = agentTabs
    }

    enum CodingKeys: String, CodingKey {
        case windows
        case collapsedGroups = "collapsed_groups"
        case agentTabs = "agent_tabs"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windows = try c.decodeIfPresent([WindowRecord].self, forKey: .windows) ?? []
        collapsedGroups = try c.decodeIfPresent([String: Bool].self, forKey: .collapsedGroups) ?? [:]
        agentTabs = try c.decodeIfPresent([String: [AgentTabRecord]].self, forKey: .agentTabs) ?? [:]
    }

    /// Replaces or appends one window by id.
    public mutating func upsert(_ window: WindowRecord) {
        if let index = windows.firstIndex(where: { $0.id == window.id }) {
            windows[index] = window
        } else {
            windows.append(window)
        }
    }

    public mutating func removeWindow(id: String) {
        windows.removeAll { $0.id == id }
    }

    /// Drops workspaces that no longer exist from every window, then every
    /// window with none left. A window exists only while it holds a
    /// workspace, so a record that never listed one (the empty state of
    /// older builds, or another client's) is dropped too.
    public mutating func prune(liveWorkspaces: Set<WorkspaceKey>) {
        windows = windows.compactMap { window in
            var window = window
            window.workspaceKeys.removeAll { !liveWorkspaces.contains($0) }
            if let shown = window.workspaceKey, !liveWorkspaces.contains(shown) { window.workspaceKey = window.workspaceKeys.first }
            return window.workspaceKey == nil && window.workspaceKeys.isEmpty ? nil : window
        }
    }

    func jsonValue() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(self))
    }

    init(jsonValue: JSONValue) throws {
        self = try JSONDecoder().decode(WindowStateDocument.self, from: JSONEncoder().encode(jsonValue))
    }
}

/// One agent chat tab in a pane's strip: its tab id and the acpmux session it shows (nil for a
/// new chat that has none yet).
public struct AgentTabRecord: Codable, Sendable, Hashable {
    public var id: String
    public var session: String?

    public init(id: String, session: String?) {
        self.id = id
        self.session = session
    }
}
