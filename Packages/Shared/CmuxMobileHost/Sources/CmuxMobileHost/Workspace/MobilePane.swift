/// A pane of a workspace: its tabs in strip order.
public struct MobilePane: Hashable, Sendable, Codable {
    public var id: String
    public var tabs: [MobileTab]

    public init(id: String, tabs: [MobileTab]) {
        self.id = id
        self.tabs = tabs
    }
}
