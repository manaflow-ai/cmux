import Foundation

/// The personal window-state document.
public struct WindowStateDocument: Codable, Sendable, Hashable {
    public static let schemaVersion: UInt32 = 1
    public var windows: [WindowRecord]
    /// Sidebar group collapse state (group key -> collapsed).
    public var collapsedGroups: [String: Bool]

    public init(windows: [WindowRecord] = [], collapsedGroups: [String: Bool] = [:]) {
        self.windows = windows
        self.collapsedGroups = collapsedGroups
    }

    enum CodingKeys: String, CodingKey {
        case windows
        case collapsedGroups = "collapsed_groups"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windows = try c.decodeIfPresent([WindowRecord].self, forKey: .windows) ?? []
        collapsedGroups = try c.decodeIfPresent([String: Bool].self, forKey: .collapsedGroups) ?? [:]
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

    /// Drops workspaces that no longer exist from every window, then windows
    /// that listed workspaces and have none left. A window that never listed
    /// any (the only window's empty state) is kept.
    public mutating func prune(liveWorkspaces: Set<WorkspaceKey>) {
        windows = windows.compactMap { window in
            var window = window
            let listed = !window.workspaceKeys.isEmpty || window.workspaceKey != nil
            window.workspaceKeys.removeAll { !liveWorkspaces.contains($0) }
            if let shown = window.workspaceKey, !liveWorkspaces.contains(shown) { window.workspaceKey = window.workspaceKeys.first }
            return listed && window.workspaceKey == nil && window.workspaceKeys.isEmpty ? nil : window
        }
    }

    func jsonValue() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(self))
    }

    init(jsonValue: JSONValue) throws {
        self = try JSONDecoder().decode(WindowStateDocument.self, from: JSONEncoder().encode(jsonValue))
    }
}
