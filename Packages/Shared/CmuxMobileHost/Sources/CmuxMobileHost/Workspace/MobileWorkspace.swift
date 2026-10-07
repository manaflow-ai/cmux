/// A workspace record of `workspace:<host>` (arrangement only, no view state).
public struct MobileWorkspace: Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    /// `#RRGGBB` or a palette token (`blue`, `red`, ...).
    public var color: String?
    /// An SF Symbol name.
    public var icon: String?
    public var pinned: Bool?
    public var order: Int
    public var group: MobileWorkspaceGroup?
    public var panes: [MobilePane]

    public init(id: String, name: String, color: String? = nil, icon: String? = nil, pinned: Bool? = nil, order: Int,
                group: MobileWorkspaceGroup? = nil, panes: [MobilePane]) {
        self.id = id
        self.name = name
        self.color = color
        self.icon = icon
        self.pinned = pinned
        self.order = order
        self.group = group
        self.panes = panes
    }

    /// Pane ids and tab ids in order: what a `workspace.upsert` must resend.
    var shape: [[String]] {
        panes.map { [$0.id] + $0.tabs.map(\.id) }
    }

    /// The record without its panes: a change here resends the workspace.
    var metadata: [String?] {
        [name, color, icon, pinned.map(String.init), String(order), group?.id, group?.name, group?.order.map(String.init)]
    }
}
