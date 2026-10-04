import Foundation

public struct WorkspaceSnapshot: Sendable, Hashable, Decodable {
    public var id: WorkspaceHandle
    /// Durable identity. Nil only on servers without `workspace-registry-v1`.
    public var key: WorkspaceKey?
    public var resourceID: ResourceID?
    public var shortID: String?
    public var name: String
    /// Shared compatibility default, not user focus. Keep focus client-local.
    public var active: Bool
    public var screens: [ScreenSnapshot]
    /// Group membership (`workspace-groups-v1`); nil = ungrouped.
    public var group: WorkspaceGroupID?
    /// Palette token or `#RRGGBB[AA]` (`workspace-metadata-v1`).
    public var color: String?
    /// SF Symbol name (`workspace-metadata-v1`).
    public var icon: String?
    /// Custom sidebar title that overrides `name` for display (`workspace-metadata-v1`).
    public var title: String?
    /// Listed in the sidebar's Pinned section (`workspace-pin-v1`).
    public var pinned: Bool
    /// Marked unread by hand (`notification-mark-unread-v1`).
    public var markedUnread: Bool
    /// `home` for the store's home workspace (`workspace-kind-v1`), else `normal`; nil on older daemons.
    public var kind: String?
    /// The store's home workspace, which no close path closes (`home_not_closable`).
    public var isHome: Bool { kind == "home" }
    /// The app of an app's companion workspace (`kind` "app_tabs",
    /// `app-screens-v1`); nil for every other workspace.
    public var app: String?
    /// Tabs with an unread marker (`notification-ack-v1`); nil on older daemons.
    public var unreadCount: Int?
    /// Contiguous screen group runs in screen order (`screen-groups-v1`).
    public var screenGroups: [ScreenGroupSnapshot] = []

    /// What a sidebar shows.
    public var displayName: String {
        if let title, !title.isEmpty { return title }
        return name
    }

    public init(
        id: WorkspaceHandle,
        key: WorkspaceKey?,
        resourceID: ResourceID? = nil,
        shortID: String? = nil,
        name: String,
        active: Bool = false,
        screens: [ScreenSnapshot] = [],
        group: WorkspaceGroupID? = nil,
        color: String? = nil,
        icon: String? = nil,
        title: String? = nil,
        pinned: Bool = false,
        markedUnread: Bool = false,
        unreadCount: Int? = nil
    ) {
        self.id = id
        self.key = key
        self.resourceID = resourceID
        self.shortID = shortID
        self.name = name
        self.active = active
        self.screens = screens
        self.group = group
        self.color = color
        self.icon = icon
        self.title = title
        self.pinned = pinned
        self.markedUnread = markedUnread
        self.unreadCount = unreadCount
    }

    enum CodingKeys: String, CodingKey {
        case id, key, name, active, screens, group, color, icon, title, pinned, kind, app
        case markedUnread = "marked_unread"
        case resourceID = "resource_id"
        case shortID = "short_id"
        case unreadCount = "unread_count"
        case screenGroups = "screen_groups"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(WorkspaceHandle.self, forKey: .id)
        key = try c.decodeIfPresent(WorkspaceKey.self, forKey: .key)
        resourceID = try c.decodeIfPresent(ResourceID.self, forKey: .resourceID)
        shortID = try c.decodeIfPresent(String.self, forKey: .shortID)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
        screens = try c.decodeIfPresent([ScreenSnapshot].self, forKey: .screens) ?? []
        group = try c.decodeIfPresent(WorkspaceGroupID.self, forKey: .group)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        markedUnread = try c.decodeIfPresent(Bool.self, forKey: .markedUnread) ?? false
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        app = (try? c.decodeIfPresent(String.self, forKey: .app)).flatMap { $0 }
        unreadCount = try c.decodeIfPresent(Int.self, forKey: .unreadCount)
        screenGroups = try c.decodeIfPresent([ScreenGroupSnapshot].self, forKey: .screenGroups) ?? []
    }
}
