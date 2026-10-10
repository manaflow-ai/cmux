public import CmuxNextDaemon
public import CmuxNextSidebar
public import CmuxNextDesign
import Foundation

/// Maps the daemon store's sidebar flattening into sidebar rows: one machine
/// section per daemon, its sections in order (loose runs and groups, which
/// may interleave with `personal-mixed-order-v1`).
public struct SidebarMapping {
    public static let shared = Self()
    /// The workspace kind of the home workspace (`workspace-kind-v1`).
    public static let homeKind = "home"

    /// What a browser workspace's row shows of its front tab's page
    /// (cx-e32b): the title in place of a name the user never gave, and the
    /// favicon in place of an icon the user never chose.
    public struct PageFace {
        public var title: String?
        public var favicon: SidebarFavicon?

        public init(title: String? = nil, favicon: SidebarFavicon? = nil) {
            self.title = title
            self.favicon = favicon
        }
    }

    /// `statusLine` maps a workspace id to the status hooks reported
    /// (`set_status`), the row's live second line. The cwd stays passive
    /// detail (tooltip, accessibility). `newTabPages` are the ids of tabs
    /// still on the New Tab page, which the tab list draws as new tabs
    /// titled `newTabTitle` (localized by the App). `pageFace` gives the page
    /// face of a workspace whose front tab is a browser, and the favicon of
    /// each browser tab in the tab list.
    public func sections(_ daemonSections: [DaemonSidebarSection], machine: SidebarMachine,
                                collapsedGroups: Set<String> = [],
                                hidesHomeWorkspace: Bool = true,
                                showsUnread: Bool = true,
                                muted: Set<String> = [],
                                statusLine: (String) -> String? = { _ in nil },
                                selectedTab: (PaneModel) -> String? = { _ in nil },
                                newTabPages: Set<String> = [], newTabTitle: String = "",
                                pageFace: (WorkspaceModel, TabModel) -> PageFace? = { _, _ in nil }) -> [SidebarRowSection] {
        var nodes: [SidebarNode] = []
        for section in daemonSections {
            // The home workspace (`kind` "home") is what the Home item in the
            // top section shows; it is not also a workspace row (nxdog28)
            // while that item is in the layout (`hidesHomeWorkspace`).
            let rows = section.workspaces.filter { !hidesHomeWorkspace || $0.kind != Self.homeKind }
                .map { row($0, machine: machine.id, status: statusLine($0.id), showsUnread: showsUnread, muted: muted.contains($0.id),
                           selectedTab: selectedTab, newTabPages: newTabPages, newTabTitle: newTabTitle, pageFace: pageFace) }
            if let group = section.group {
                nodes.append(.group(SidebarGroup(
                    id: GroupID(group.id.rawValue),
                    name: group.name,
                    color: color(group.color) ?? .grey,
                    isCollapsed: group.collapsed || collapsedGroups.contains(group.id.rawValue),
                    isPinned: group.pinned,
                    icon: group.icon.flatMap { WorkspaceIcon.parse($0) },
                    workspaces: rows
                )))
            } else {
                nodes += rows.map(SidebarNode.workspace)
            }
        }
        return [SidebarRowSection(kind: .machine(machine), nodes: nodes)]
    }

    /// `showsUnread: false` hides the unread badge (`notifications.attention.showOnSidebar`).
    /// `selectedTab` is the window's tab selection in a pane (a `TabModel.id`), nil for the
    /// daemon's default tab. `newTabPages` are the ids of tabs still on the New Tab page,
    /// listed as `newTabTitle` when it is not empty.
    /// `muted`: the workspace is in `notifications.mutedWorkspaces`.
    public func row(_ workspace: WorkspaceModel, machine: MachineID, status: String? = nil, showsUnread: Bool = true,
                    muted: Bool = false, selectedTab: (PaneModel) -> String? = { _ in nil }, newTabPages: Set<String> = [],
                    newTabTitle: String = "", pageFace: (WorkspaceModel, TabModel) -> PageFace? = { _, _ in nil }) -> SidebarWorkspace {
        let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
        let unread = showsUnread ? workspace.unreadCount : 0
        let indicator = StatusMapping.shared.summary(tabs: tabs)
        let front = frontTab(workspace, selectedTab: selectedTab)
        let folder = folderTab(tabs)
        let page = front.flatMap { $0.kind == .browser ? pageFace(workspace, $0) : nil }
        let entries = workspace.status?.entries ?? []
        // Another computer's folders shorten against that computer's home, never this Mac's (cx-gaq9).
        let shorten: (String) -> String = machine == .local ? { abbreviate($0) } : Self.abbreviateRemote
        return SidebarWorkspace(
            id: SidebarWorkspaceID(workspace.id),
            machineID: machine,
            title: page?.title ?? workspace.displayName,
            directory: folder?.cwd.map(shorten),
            branch: folder?.gitBranch.flatMap { $0.isEmpty ? nil : $0 },
            process: process(front),
            // The hooks' status line, else the daemon's workspace status
            // (state resources) without the entries other elements show.
            status: (status ?? Self.statusLine(entries)).flatMap { $0.isEmpty ? nil : $0 },
            ports: Self.entry(Self.portsKey, in: entries),
            pullRequest: Self.entry(Self.pullRequestKey, in: entries),
            lastActivity: lastActivity(tabs),
            rowKind: rowKind(tabs),
            agentWorking: StatusMapping.shared.isWorking(tabs: tabs),
            icon: Self.icon(color: workspace.color, icon: workspace.icon) ?? page?.favicon.map(WorkspaceIcon.favicon),
            kind: kind(front),
            kindBrand: front?.agentBrand,
            unread: unread > 0 ? .count(unread) : (showsUnread && workspace.markedUnread ? .dot : .none),
            activity: indicator.state,
            activityStyle: indicator.style,
            agentBrand: agentBrand(tabs),
            progress: progress(workspace, tabs: tabs),
            tabs: tabs.map { tab in
                let isNewTabPage = newTabPages.contains(tab.id) && !newTabTitle.isEmpty
                return SidebarTab(id: TabID(tab.id), title: isNewTabPage ? newTabTitle : tab.displayTitle,
                                  kind: Self.listedKind(tab, newTabPages: newTabPages), isUnread: tab.hasUnread,
                                  brand: tab.agentBrand, favicon: tab.kind == .browser ? pageFace(workspace, tab)?.favicon : nil)
            },
            muted: muted,
            // The store refuses every close of its home workspace (`home_not_closable`).
            isClosable: workspace.kind != Self.homeKind,
            // Group by Folder's bucket: the front tab's folder, else any tab's.
            folder: (front?.cwd ?? tabs.lazy.compactMap(\.cwd).first).map(shorten)
        )
    }

    /// The tab the row stands for: the selected tab of the workspace's most
    /// recently focused pane; nil for a workspace with no tabs.
    func frontTab(_ workspace: WorkspaceModel, selectedTab: (PaneModel) -> String?) -> TabModel? {
        let panes = workspace.screens.flatMap(\.panes).filter { !$0.tabs.isEmpty }
        guard let pane = panes.max(by: { $0.focusedAt < $1.focusedAt }) else { return nil }
        if let id = selectedTab(pane), let tab = pane.tabs.first(where: { $0.id == id }) { return tab }
        return pane.tabs[min(max(pane.defaultTabIndex, 0), pane.tabs.count - 1)]
    }

    /// What a tab shows: an agent (chat, Home conversation or agent terminal),
    /// a page, else a terminal.
    func kind(_ tab: TabModel?) -> SidebarWorkspaceKind {
        guard let tab else { return .terminal }
        if tab.kind == .conversation || tab.agent != nil { return .harness }
        return tab.kind == .browser ? .browser : .terminal
    }

    /// The brand of the agent running in these tabs (design/agent-icons): the first that
    /// works or waits, else the first live one.
    func agentBrand(_ tabs: [TabModel]) -> String? {
        let busy = tabs.lazy.filter { $0.agent?.state == .working || $0.agent?.state == .blocked }.compactMap(\.agentBrand).first
        return busy ?? tabs.lazy.compactMap(\.agentBrand).first
    }

    /// A tab's kind in the tab list: a New Tab page, an agent chat, else its record's kind.
    private static func listedKind(_ tab: TabModel, newTabPages: Set<String>) -> SidebarTabKind {
        if newTabPages.contains(tab.id) { return .newTab }
        return tab.agentSession == nil ? tabKind(tab.kind) : .agentChat
    }

    private static func tabKind(_ kind: TabKind) -> SidebarTabKind {
        switch kind {
        case .pty: .terminal
        case .browser: .browser
        case .remoteTerminal: .remoteTerminal
        case .conversation: .conversation
        case let .other(value): .other(value)
        }
    }

    /// The workspace's reported progress, else the first terminal progress
    /// the daemon parsed for one of its tabs (mounted or not).
    public func progress(_ workspace: WorkspaceModel, tabs: [TabModel]) -> SidebarProgress? {
        if let reported = workspace.status?.progress { return SidebarProgress(value: reported.value) }
        guard let terminal = tabs.lazy.compactMap(\.progress).first else { return nil }
        return Self.progress(terminal)
    }

    /// A terminal's OSC 9;4 progress as a bar; nil for a paused one with no value.
    public static func progress(_ report: TerminalProgressReport) -> SidebarProgress? {
        let value = report.value.map { Double($0) / 100 }
        switch report.state {
        case .normal: return SidebarProgress(value: value)
        case .error: return SidebarProgress(value: value ?? 1, isError: true)
        case .indeterminate: return SidebarProgress(value: nil)
        case .paused: return value.map { SidebarProgress(value: $0) }
        }
    }

    /// Status entry keys that feed their own row elements, not the status
    /// line (`cmux workspace status set ports|pr <text>`).
    public static let portsKey = "ports"
    public static let pullRequestKey = "pr"

    /// The status line: every entry but the ones other elements show.
    static func statusLine(_ entries: [WorkspaceStatus.Entry]) -> String? {
        let texts = entries.filter { $0.key != portsKey && $0.key != pullRequestKey }.map(\.text).filter { !$0.isEmpty }
        return texts.isEmpty ? nil : texts.joined(separator: " · ")
    }

    static func entry(_ key: String, in entries: [WorkspaceStatus.Entry]) -> String? {
        entries.first { $0.key == key && !$0.text.isEmpty }?.text
    }

    /// The first tab that reports a folder: the row's folder and branch.
    func folderTab(_ tabs: [TabModel]) -> TabModel? {
        tabs.first { $0.cwd != nil }
    }

    /// The front terminal's program as the shell or program titles it (OSC
    /// 0/2); nil for other tabs, an untitled terminal, or a title that only
    /// repeats the folder.
    func process(_ tab: TabModel?) -> String? {
        guard let tab, tab.kind == .pty, tab.agent == nil else { return nil }
        let title = tab.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        if let cwd = tab.cwd, title == cwd || title == abbreviate(cwd) { return nil }
        return title
    }

    /// The newest agent update or notification of the tabs; nil without one.
    func lastActivity(_ tabs: [TabModel]) -> Date? {
        let newest = tabs.map { max($0.agent?.updatedAtMs ?? 0, $0.notification?.createdAtMs ?? 0) }.max() ?? 0
        return newest == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(newest) / 1000)
    }

    /// What the tabs are: one kind, or mixed; a workspace without tabs is a terminal one.
    func rowKind(_ tabs: [TabModel]) -> WorkspaceRowKind {
        let kinds = Set(tabs.map { tab -> WorkspaceRowKind in
            switch kind(tab) {
            case .harness: .agent
            case .browser: .browser
            case .terminal: .terminal
            }
        })
        guard kinds.count <= 1 else { return .mixed }
        return kinds.first ?? .terminal
    }

    /// A folder of another computer (SSH, Cloud) as its shell prompt writes it: its account's
    /// home (`/Users/<name>` or `/home/<name>`) as `~`. The app does not know that machine's home
    /// otherwise, and this Mac's home says nothing about it (cx-gaq9).
    public static func abbreviateRemote(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].isEmpty, parts[1] == "Users" || parts[1] == "home", !parts[2].isEmpty,
              parts[2] != "Shared" else { return path }
        return (["~"] + parts.dropFirst(3)).joined(separator: "/")
    }

    func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// A workspace's sidebar icon: its icon with its color (a tinted symbol,
    /// an emoji on a color chip), else its color as a swatch, else none.
    public static func icon(color name: String?, icon: String?) -> WorkspaceIcon? {
        let color = shared.color(name)
        return icon.flatMap { WorkspaceIcon.parse($0, color: color) } ?? color.map(WorkspaceIcon.swatch)
    }

    public func color(_ name: String?) -> GroupColor? {
        guard let name else { return nil }
        return GroupColor(rawValue: name.lowercased()) ?? (name.lowercased() == "gray" ? .grey : nil)
    }
}
