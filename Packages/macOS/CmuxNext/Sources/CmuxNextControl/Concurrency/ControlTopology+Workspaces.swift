public struct ControlWorkspaceGroupInfo: Sendable, Hashable {
    public var id: String
    public var name: String
    public var color: String?
    public var isCollapsed: Bool

    public init(id: String, name: String, color: String?, isCollapsed: Bool) {
        self.id = id
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
    }
}

public struct ControlWorkspaceInfo: Sendable, Hashable {
    /// Durable workspace key (falls back to the handle before one exists).
    public var id: String
    public var handle: String
    public var name: String
    public var title: String?
    public var color: String?
    public var icon: String?
    public var groupID: String?
    public var unreadCount: Int
    public var screens: [ControlScreenInfo]

    public init(id: String, handle: String, name: String, title: String? = nil, color: String? = nil, icon: String? = nil,
                groupID: String? = nil, unreadCount: Int = 0, screens: [ControlScreenInfo] = []) {
        self.id = id
        self.handle = handle
        self.name = name
        self.title = title
        self.color = color
        self.icon = icon
        self.groupID = groupID
        self.unreadCount = unreadCount
        self.screens = screens
    }

    public var panes: [ControlPaneInfo] { screens.flatMap(\.panes) }
}

public struct ControlScreenInfo: Sendable, Hashable {
    public var id: String
    public var handle: String
    public var name: String?
    public var zoomedPaneID: String?
    public var panes: [ControlPaneInfo]

    public init(id: String, handle: String, name: String? = nil, zoomedPaneID: String? = nil, panes: [ControlPaneInfo] = []) {
        self.id = id
        self.handle = handle
        self.name = name
        self.zoomedPaneID = zoomedPaneID
        self.panes = panes
    }
}
