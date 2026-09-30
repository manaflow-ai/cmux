import Foundation
public import Observation

@Observable @MainActor
public final class WorkspaceModel: Identifiable {
    /// Durable key (or `handle:<n>` on servers without the registry).
    public let id: String
    public internal(set) var key: WorkspaceKey?
    public internal(set) var handle: WorkspaceHandle
    /// Durable resource id (`ws_…`) on registry daemons.
    public internal(set) var resourceID: ResourceID?
    public internal(set) var name: String
    public internal(set) var screens: [ScreenModel]
    public internal(set) var group: WorkspaceGroupID?
    public internal(set) var color: String?
    public internal(set) var icon: String?
    public internal(set) var title: String?
    /// Daemon rollup (`notification-ack-v1`); nil on older daemons.
    public internal(set) var daemonUnreadCount: Int?

    /// Custom title when set, else the name.
    public var displayName: String {
        if let title, !title.isEmpty { return title }
        return name
    }

    /// Tabs with an unread marker, counted from the mirrored tabs, which
    /// every tab delta (an acknowledgement included) keeps current. The
    /// daemon rollup arrives only with workspace snapshots, so it goes stale
    /// after an ack; it serves only a workspace whose tree is not mirrored.
    public var unreadCount: Int {
        guard !screens.isEmpty else { return daemonUnreadCount ?? 0 }
        return screens.reduce(0) { total, screen in
            total + screen.panes.reduce(0) { $0 + $1.tabs.filter(\.hasUnread).count }
        }
    }

    init(_ s: WorkspaceSnapshot) {
        id = Self.identity(s)
        key = s.key
        handle = s.id
        resourceID = s.resourceID
        name = s.name
        screens = s.screens.map(ScreenModel.init)
        group = s.group
        color = s.color
        icon = s.icon
        title = s.title
        daemonUnreadCount = s.unreadCount
    }

    static func identity(_ s: WorkspaceSnapshot) -> String {
        s.key?.rawValue ?? "handle:\(s.id.rawValue)"
    }

    func update(_ s: WorkspaceSnapshot) {
        if key != s.key { key = s.key }
        if resourceID != s.resourceID { resourceID = s.resourceID }
        if handle != s.id { handle = s.id }
        if name != s.name { name = s.name }
        if group != s.group { group = s.group }
        if color != s.color { color = s.color }
        if icon != s.icon { icon = s.icon }
        if title != s.title { title = s.title }
        if daemonUnreadCount != s.unreadCount { daemonUnreadCount = s.unreadCount }
        if let reordered = reconcile(screens, with: s.screens, id: ScreenModel.identity, make: ScreenModel.init, update: { $0.update($1) }) {
            screens = reordered
        }
    }

    func setName(_ value: String) { if name != value { name = value } }
    func setGroup(_ value: WorkspaceGroupID?) { if group != value { group = value } }
}
