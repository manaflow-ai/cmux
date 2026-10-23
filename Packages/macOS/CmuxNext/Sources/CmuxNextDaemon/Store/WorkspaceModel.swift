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
    public internal(set) var nameSource: WorkspaceNameSource
    public internal(set) var nameRevision: UInt64
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
    /// The folder new agent chats of this workspace start in, set by the user with "Choose
    /// Folder…" (`workspace.agent_folder.set`); from the daemon's state resources.
    public internal(set) var agentFolder: String?
    /// The person's notes for the workspace (Edit Workspace Description…,
    /// `workspace-description-v1`); from the daemon's state resources.
    public internal(set) var workspaceDescription: String?
    /// The task lane the person pinned (Mark as Done, Set Workspace Status,
    /// `workspace-status-v1`); nil is automatic. From the daemon's state resources.
    public internal(set) var taskStatus: WorkspaceTaskStatus?
    /// Status line, progress, and newest log line hooks and the CLI report
    /// (`workspace_status.*`); from the daemon's state resources.
    public internal(set) var status: WorkspaceStatus?
    /// The checklist, in list order (`workspace_checklist.*`, `workspace-checklist-v1`); from the
    /// daemon's state resources. Empty without items or on a daemon that keeps none.
    public internal(set) var checklist: [WorkspaceChecklistItem] = []
    /// Screen groups come from the daemon's state resources.
    @ObservationIgnored var screenGroupsFromState = false
    /// Listed in the sidebar's Pinned section (`workspace-pin-v1`).
    public internal(set) var pinned: Bool
    /// Marked unread by hand (`notification-mark-unread-v1`), apart from
    /// notification markers; cleared when the workspace is used.
    public internal(set) var markedUnread: Bool
    /// `home` for the store's home workspace (`workspace-kind-v1`).
    public internal(set) var kind: String?
    /// The app of an app workspace (`app-screens-v1`): its one pane shows the
    /// app without a tab strip.
    public internal(set) var app: String?
    /// Daemon rollup (`notification-ack-v1`); nil on older daemons.
    public internal(set) var daemonUnreadCount: Int?

    /// A stand-in Cmd-N shows before the daemon has the workspace (``ProvisionalWorkspace``):
    /// its handle names no daemon workspace, so no command may target it yet.
    public var isProvisional: Bool { ProvisionalWorkspace.isProvisional(handle) }
    /// Its id in the store's list check: a stand-in's takeover by the daemon's workspace is a list change.
    var listID: String { isProvisional ? id + "~" : id }

    /// Custom title when set, else the name.
    public var displayName: String {
        if let title, !title.isEmpty { return title }
        return name
    }

    /// Nobody named the workspace: no title, and the daemon's default name.
    public var isUnnamed: Bool { (title ?? "").isEmpty && Self.isDefaultName(name) }

    /// True for a name the daemon gave (`workspace-N`, its default), including
    /// the empty and home-folder defaults retained by older daemons.
    /// A user could name a workspace `workspace-7` by hand; the daemon
    /// records no "named by the user" flag, so that name reads as default.
    public nonisolated static func isDefaultName(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "~" { return true }
        guard name.hasPrefix("workspace-") else { return false }
        let number = name.dropFirst("workspace-".count)
        return !number.isEmpty && number.allSatisfy(\.isASCII) && number.allSatisfy(\.isNumber)
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
        nameSource = s.nameSource
        nameRevision = s.nameRevision
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
        if nameSource != s.nameSource { nameSource = s.nameSource }
        if nameRevision != s.nameRevision { nameRevision = s.nameRevision }
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
    func applyState(ephemeral: Bool, agentFolder: String? = nil, notes: SessionStateMirror.WorkspaceNotes = .init(),
                    status: WorkspaceStatus?, checklist: [WorkspaceChecklistItem] = [],
                    screenGroups groups: [ScreenGroupSnapshot]?) {
        if self.ephemeral != ephemeral { self.ephemeral = ephemeral }
        if self.agentFolder != agentFolder { self.agentFolder = agentFolder }
        if workspaceDescription != notes.description { workspaceDescription = notes.description }
        if taskStatus != notes.taskStatus { taskStatus = notes.taskStatus }
        if self.status != status { self.status = status }
        if self.checklist != checklist { self.checklist = checklist }
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
