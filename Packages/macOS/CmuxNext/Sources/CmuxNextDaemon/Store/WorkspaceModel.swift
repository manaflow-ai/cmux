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
    /// Screen group runs in screen order (`screen-groups-v1`).
    public internal(set) var screenGroups: [ScreenGroupSnapshot]
    public internal(set) var group: WorkspaceGroupID?
    public internal(set) var color: String?
    public internal(set) var icon: String?
    public internal(set) var title: String?
    /// Closed by the daemon at its next start (incognito); from the daemon's
    /// state resources (`DaemonStore.session`).
    public internal(set) var ephemeral = false
    /// Status line, progress, and newest log line hooks and the CLI report
    /// (`workspace_status.*`); from the daemon's state resources.
    public internal(set) var status: WorkspaceStatus?
    /// Screen groups come from the daemon's state resources.
    @ObservationIgnored var screenGroupsFromState = false
    /// Listed in the sidebar's Pinned section (`workspace-pin-v1`).
    public internal(set) var pinned: Bool
    /// Marked unread by hand (`notification-mark-unread-v1`), apart from
    /// notification markers; cleared when the workspace is used.
    public internal(set) var markedUnread: Bool
    /// `home` for the store's home workspace (`workspace-kind-v1`).
    public internal(set) var kind: String?
    /// The app of an app's companion workspace (`kind` "app_tabs").
    public internal(set) var app: String?
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
        screenGroups = s.screenGroups
        group = s.group
        color = s.color
        icon = s.icon
        title = s.title
        pinned = s.pinned
        markedUnread = s.markedUnread
        kind = s.kind
        app = s.app
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
        if pinned != s.pinned { pinned = s.pinned }
        if markedUnread != s.markedUnread { markedUnread = s.markedUnread }
        if kind != s.kind { kind = s.kind }
        if app != s.app { app = s.app }
        if daemonUnreadCount != s.unreadCount { daemonUnreadCount = s.unreadCount }
        if !screenGroupsFromState, screenGroups != s.screenGroups { screenGroups = s.screenGroups }
        if let reordered = reconcile(screens, with: s.screens, id: ScreenModel.identity, make: ScreenModel.init, update: { $0.update($1) }) {
            screens = reordered
        }
    }

    /// Lays the daemon's workspace state over the record.
    func applyState(ephemeral: Bool, status: WorkspaceStatus?, screenGroups groups: [ScreenGroupSnapshot]?) {
        if self.ephemeral != ephemeral { self.ephemeral = ephemeral }
        if self.status != status { self.status = status }
        screenGroupsFromState = groups != nil
        if let groups, screenGroups != groups { screenGroups = groups }
    }

    func setName(_ value: String) { if name != value { name = value } }
    func setGroup(_ value: WorkspaceGroupID?) { if group != value { group = value } }

    /// Moves `screen` to `index` (a `screen-changed` delta whose index differs).
    func moveScreen(_ screen: ScreenModel, to index: Int) {
        guard let from = screens.firstIndex(where: { $0 === screen }) else { return }
        let target = min(max(index, 0), screens.count - 1)
        guard from != target else { return }
        var reordered = screens
        reordered.remove(at: from)
        reordered.insert(screen, at: target)
        screens = reordered
    }
}
