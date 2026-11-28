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
    /// Durable public id (`ws_…`) on registry daemons; `id` is the durable key.
    public var resourceID: String?
    public var handle: String
    public var name: String
    public var title: String?
    public var color: String?
    public var icon: String?
    public var groupID: String?
    public var unreadCount: Int
    public var screens: [ControlScreenInfo]
    /// The machine whose daemon holds the workspace; nil for the local daemon.
    public var machine: String?

    /// The id clients print and pass: `ws_…` on registry daemons, else the key.
    public var publicID: String { resourceID ?? id }
    /// The workspace's home session (`ControlSessionInfo.id`); nil for the
    /// app's home session. Its handles are valid only on that session.
    public var sessionID: String?
    /// The workspace kind (`home` for the chief's Home workspace, which a
    /// window draws as the Home page, not as panes); nil for an ordinary one.
    public var kind: String?

    public init(id: String, handle: String, name: String, title: String? = nil, color: String? = nil, icon: String? = nil,
                groupID: String? = nil, unreadCount: Int = 0, screens: [ControlScreenInfo] = [], sessionID: String? = nil) {
        self.sessionID = sessionID
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
    /// The daemon's active pane of the screen (its default for a new tab).
    public var defaultPaneID: String?
    public var panes: [ControlPaneInfo]

    public init(id: String, handle: String, name: String? = nil, zoomedPaneID: String? = nil, panes: [ControlPaneInfo] = []) {
        self.id = id
        self.handle = handle
        self.name = name
        self.zoomedPaneID = zoomedPaneID
        self.panes = panes
    }
}
