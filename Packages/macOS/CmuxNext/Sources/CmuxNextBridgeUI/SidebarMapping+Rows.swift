public import CmuxNextBridge
public import CmuxNextDaemon
public import CmuxNextDesign
public import CmuxNextSidebar
import Foundation

/// Maps the daemon store's sidebar flattening into sidebar rows: one machine
/// section per daemon, its sections in order (loose runs and groups, which
/// may interleave with `personal-mixed-order-v1`).
extension SidebarMapping {
    /// What a workspace's row shows of its front tab: a name in place of one
    /// the user never gave (a page's title, cx-e32b; a chat's or terminal's,
    /// hq#1957), and a page's favicon in place of an icon the user never chose.
    /// A daemon default name (`workspace-7`) remains visible until a rename.
    private static func sidebarTitle(_ workspace: WorkspaceModel, page: PageFace?) -> String {
        if let pageTitle = page?.title, !pageTitle.isEmpty { return pageTitle }
        return workspace.displayName
    }
    /// Supplies a row in place of mapping it now: the workspace, its machine, and the mapping to run later.
    public typealias RowSource = (WorkspaceModel, MachineID, @escaping SidebarRowFeed.Make) -> SidebarWorkspace

    /// What a browser workspace's row shows of its front tab's page
    /// (cx-e32b): the title in place of a name the user never gave, and the
    /// favicon in place of an icon the user never chose.
    public struct PageFace {
        public var title: String?
        public var favicon: SidebarFavicon?
        /// The page's sound (a browser tab playing sound or muted); the row
        /// merges its tabs' (`SidebarWorkspaceAudio.merge`).
        public var audio: SidebarWorkspaceAudio?

        public init(title: String? = nil, favicon: SidebarFavicon? = nil, audio: SidebarWorkspaceAudio? = nil) {
            self.title = title
            self.favicon = favicon
            self.audio = audio
        }
    }

    /// `statusLine` maps a workspace id to the status hooks reported
    /// (`set_status`), the row's live second line. The cwd stays passive
    /// detail (tooltip, accessibility). `newTabPages` are the ids of tabs
    /// still on the New Tab page, which the tab list draws as new tabs
    /// titled `newTabTitle` (localized by the App). `pageFace` gives the face
    /// a workspace's front tab (any kind) lends its row, given the work tab a
    /// browser front tab yields its name to (`workTab`), and the favicon of
    /// each browser tab in the tab list (no work tab). `tabTitle` names each tab in the tab
    /// list as its strip does (the App's `TabTitleResolver`); without it a
    /// tab shows its record's title. `iconAsset` draws a stored image or SVG
    /// icon (`image:` / `svg:sha256-<hex>`); nil while it loads.
    /// `rowSource`, when given, supplies each row instead of mapping it here:
    /// it gets the workspace and the mapping to run later (`SidebarRowFeed`),
    /// so a structural pass reads no row's status.
    /// `workspaceFilter` drops workspaces that are no longer valid sidebar rows
    /// (for example, an acpmux session that was purged while its tab lingers).
    public func sections(_ daemonSections: [DaemonSidebarSection], machine: SidebarMachine,
                                collapsedGroups: Set<String> = [],
                                hidesHomeWorkspace: Bool = true,
                                showsUnread: Bool = true,
                                muted: Set<String> = [],
                                statusLine: @escaping (String) -> String? = { _ in nil },
                                selectedTab: @escaping (PaneModel) -> String? = { _ in nil },
                                newTabPages: Set<String> = [], newTabTitle: String = "",
                                pageFace: @escaping (WorkspaceModel, TabModel, TabModel?) -> PageFace? = { _, _, _ in nil },
                                tabTitle: ((TabModel) -> String)? = nil, notificationText: @escaping (TabModel) -> String? = { _ in nil },
                                iconAsset: @escaping (String) -> SidebarFavicon? = { _ in nil },
                                groupIconAsset: ((String) -> SidebarFavicon?)? = nil,
                                rowSource: RowSource? = nil,
                                workspaceFilter: (WorkspaceModel) -> Bool = { _ in true }) -> [SidebarRowSection] {
        // A personal group's icon lives on the home daemon, whichever machine's section shows it.
        func groupImage(_ icon: String) -> SidebarFavicon? { groupIconAsset.map { $0(icon) } ?? iconAsset(icon) }
        var nodes: [SidebarNode] = []
        for section in daemonSections {
            // The home workspace (`kind` "home") is what the Home item in the
            // top section shows; it is not also a workspace row (nxdog28)
            // while that item is in the layout (`hidesHomeWorkspace`).
            let rows = section.workspaces.filter { (!hidesHomeWorkspace || $0.kind != Self.homeKind) && workspaceFilter($0) }
                .map { workspace in
                    let make = { row(workspace, machine: machine.id, status: statusLine(workspace.id), showsUnread: showsUnread,
                                     muted: muted.contains(workspace.id), selectedTab: selectedTab, newTabPages: newTabPages,
                                     newTabTitle: newTabTitle, pageFace: pageFace, tabTitle: tabTitle,
                                     notificationText: notificationText, iconAsset: iconAsset) }
                    return rowSource.map { $0(workspace, machine.id, make) } ?? make()
                }
            if let group = section.group {
                var made = SidebarGroup(
                    id: GroupID(group.id.rawValue),
                    name: group.name,
                    // No stored color (a group an agent or the CLI made): a stable palette color, not grey.
                    color: group.color == GroupTint.noneWire ? .grey : color(group.color) ?? .unset(id: group.id.rawValue),
                    // A custom `#RRGGBB` (cx-25az) or no color (`none`) draws instead of the token.
                    custom: group.color.flatMap { $0.hasPrefix("#") || $0 == GroupTint.noneWire ? GroupTint(wire: $0)?.wire : nil },
                    isCollapsed: group.collapsed || collapsedGroups.contains(group.id.rawValue),
                    isPinned: group.pinned,
                    icon: group.icon.flatMap { groupImage($0).map(WorkspaceIcon.favicon) ?? WorkspaceIcon.parse($0) },
                    workspaces: rows
                )
                made.parent = group.parent.map { GroupID($0.rawValue) }
                made.depth = group.depth
                nodes.append(.group(made))
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
    /// `muted`: the workspace is in `notifications.mutedWorkspaces`. `notificationText` is the
    /// text of a tab's unread notification (`DaemonStore.notificationText(for:)`).
    /// `iconAsset` draws a stored image or SVG icon, as in `sections`.
    public func row(_ workspace: WorkspaceModel, machine: MachineID, status: String? = nil, showsUnread: Bool = true,
                    muted: Bool = false, selectedTab: (PaneModel) -> String? = { _ in nil }, newTabPages: Set<String> = [],
                    newTabTitle: String = "", pageFace: (WorkspaceModel, TabModel, TabModel?) -> PageFace? = { _, _, _ in nil },
                    tabTitle: ((TabModel) -> String)? = nil, notificationText: (TabModel) -> String? = { _ in nil },
                    iconAsset: (String) -> SidebarFavicon? = { _ in nil }) -> SidebarWorkspace {
        let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
        let unread = showsUnread ? workspace.unreadCount : 0
        let indicator = StatusMapping.shared.summary(tabs: tabs, status: workspace.status)
        let front = frontTab(workspace, selectedTab: selectedTab)
        let folder = folderTab(tabs)
        let work = front?.kind == .browser ? workTab(workspace, selectedTab: selectedTab) : nil
        let page = front.flatMap { pageFace(workspace, $0, work) }
        // Each browser tab's face once: its favicon in the tab list, its sound on the row.
        var browserFaces: [String: PageFace] = [:]
        for tab in tabs where tab.kind == .browser {
            browserFaces[tab.id] = tab.id == front?.id ? page : pageFace(workspace, tab, nil)
        }
        let entries = workspace.status?.entries ?? []
        // Another computer's folders shorten against that computer's home, never this Mac's (cx-gaq9).
        let shorten: (String) -> String = machine == .local ? { abbreviate($0) } : Self.abbreviateRemote
        let title = Self.sidebarTitle(workspace, page: page)
        var row = SidebarWorkspace(
            id: SidebarWorkspaceID(workspace.id),
            machineID: machine,
            // An older Chief's subagent workspaces show their task title, never the subagent id.
            title: machine.isLocalChief ? title.chiefTaskTitle ?? title : title,
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
            // A page in a split beside a chat or terminal leaves the row's icon to that work, as it
            // leaves its name (#22250; Leo 2026-10-21: "why did this turn into the githb favicon?").
            icon: Self.icon(color: workspace.color, icon: workspace.icon, asset: iconAsset)
                ?? (work == nil ? page?.favicon.map(WorkspaceIcon.favicon) : nil),
            kind: kind(front),
            kindBrand: front?.agentBrand,
            // A tab marked unread by hand (Mark Tab Unread) shows as the workspace's manual dot.
            unread: unread > 0 ? .count(unread)
                : (showsUnread && (workspace.markedUnread || tabs.contains(where: \.markedUnread)) ? .dot : .none),
            activity: indicator.state,
            activityStyle: indicator.style,
            agentBrand: agentBrand(tabs),
            agentName: agentTab(tabs)?.agentName,
            progress: progress(workspace, tabs: tabs),
            tabs: tabs.map { tab in
                let isNewTabPage = newTabPages.contains(tab.id) && !newTabTitle.isEmpty
                let title = tabTitle?(tab) ?? (isNewTabPage ? newTabTitle : tab.displayTitle)
                return SidebarTab(id: TabID(tab.id), title: title,
                                  kind: Self.listedKind(tab, newTabPages: newTabPages), isUnread: tab.showsUnread,
                                  brand: tab.agentBrand, favicon: browserFaces[tab.id]?.favicon)
            },
            muted: muted,
            // The store refuses every close of its home workspace (`home_not_closable`).
            isClosable: workspace.kind != Self.homeKind,
            // Group by Folder's bucket: the front tab's folder, else any tab's.
            folder: (front?.cwd ?? tabs.lazy.compactMap(\.cwd).first).map(shorten)
        )
        row.presence = presence(tabs)
        row.isUnnamed = Self.isUnnamed(workspace, label: page?.title)
        row.audio = SidebarWorkspaceAudio.merge(tabs.lazy.map { browserFaces[$0.id]?.audio })
        row.lastMessage = lastMessage(front, tabs)
        if showsUnread { row.notificationText = newestUnread(tabs).flatMap(notificationText) }
        row.reported = Self.reported(workspace.status, asset: iconAsset)
        row.workspaceDescription = workspace.workspaceDescription
        row.taskStatus = workspace.taskStatus.map(Self.taskStatus)
        row.checklist = workspace.checklist.map(Self.checklistItem)
        row.detail = detail(tabs: tabs, indicator: indicator.state, agentTab: agentTab(tabs), front: front,
                            notification: row.notificationText)
        return row
    }

    /// A daemon checklist item as the sidebar draws it.
    static func checklistItem(_ item: WorkspaceChecklistItem) -> SidebarChecklistItem {
        let state: SidebarChecklistItem.State = switch item.state {
        case .todo: .todo
        case .inProgress: .inProgress
        case .done: .done
        }
        return SidebarChecklistItem(id: item.id, text: item.text, state: state, attachmentCount: item.attachments.count)
    }

    /// What a tab shows: an agent (chat, Home conversation or agent terminal),
    /// a page, else a terminal.
    func kind(_ tab: TabModel?) -> SidebarWorkspaceKind {
        guard let tab else { return .terminal }
        if tab.kind == .conversation || tab.agent != nil { return .harness }
        return tab.kind == .browser ? .browser : .terminal
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

    /// The sidebar's lane for a workspace's manual task status (`workspace-status-v1`).
    static func taskStatus(_ status: WorkspaceTaskStatus) -> SidebarTaskStatus {
        switch status {
        case .todo: .todo
        case .working: .working
        case .needsAttention: .needsAttention
        case .review: .review
        case .done: .done
        }
    }

    /// The status block: every entry but the ones other elements show, the
    /// newest log line and the progress label; nil when none is reported. `asset` draws an
    /// entry's stored image or SVG icon.
    static func reported(_ status: WorkspaceStatus?, asset: (String) -> SidebarFavicon? = { _ in nil }) -> SidebarWorkspaceStatus? {
        guard let status else { return nil }
        let block = SidebarWorkspaceStatus(
            entries: status.entries.filter { $0.key != portsKey && $0.key != pullRequestKey }.map {
                SidebarWorkspaceStatus.Entry(key: $0.key, text: $0.text, icon: $0.icon, tint: SidebarWorkspaceStatus.Tint($0.color), state: $0.state,
                                             image: $0.icon.flatMap(asset))
            },
            log: status.lastLog.map {
                SidebarWorkspaceStatus.LogLine(level: SidebarWorkspaceStatus.LogLevel(rawValue: $0.level) ?? .info, text: $0.text)
            },
            progressLabel: status.progress?.label)
        return block.isEmpty ? nil : block
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

    /// A workspace's sidebar icon: its icon with its color (a tinted symbol,
    /// an emoji on a color chip, a stored image or SVG as drawn by `asset`,
    /// a placeholder symbol while it loads), else its color as a swatch, else none.
    public static func icon(color name: String?, icon: String?,
                            asset: (String) -> SidebarFavicon? = { _ in nil }) -> WorkspaceIcon? {
        let color = shared.color(name)
        if let icon, let image = asset(icon) { return .favicon(image) }
        return icon.flatMap { WorkspaceIcon.parse($0, color: color) } ?? color.map(WorkspaceIcon.swatch)
    }

    public func color(_ name: String?) -> GroupColor? {
        guard let name else { return nil }
        return GroupColor(rawValue: name.lowercased()) ?? (name.lowercased() == "gray" ? .grey : nil)
    }
}

extension SidebarRowFeed {
    /// This feed as the mapping's row source (`SidebarMapping.sections(rowSource:)`).
    public var rowSource: SidebarMapping.RowSource {
        { workspace, machine, make in self.row(SidebarWorkspaceID(workspace.id), machine: machine, make: make) }
    }
}
