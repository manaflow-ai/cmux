/// A workspace record of `workspace:<host>` (arrangement only, no view state).
public struct MobileWorkspace: Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    public var color: String?
    public var pinned: Bool?
    public var order: Int
    public var panes: [MobilePane]

    public init(id: String, name: String, color: String? = nil, pinned: Bool? = nil, order: Int, panes: [MobilePane]) {
        self.id = id
        self.name = name
        self.color = color
        self.pinned = pinned
        self.order = order
        self.panes = panes
    }

    /// Pane ids and tab ids in order: what a `workspace.upsert` must resend.
    var shape: [[String]] {
        panes.map { [$0.id] + $0.tabs.map(\.id) }
    }
}
