public import CmuxNextDaemon
public import CmuxNextSidebar
public import CmuxNextDesign
import Foundation

/// Maps the daemon store's sidebar flattening into sidebar rows: one machine
/// section per daemon, its sections in order (loose runs and groups, which
/// may interleave with `personal-mixed-order-v1`).
public struct SidebarMapping {
    public static let shared = Self()
    /// This Mac's home folder as a native string, read once: `NSHomeDirectory()` hands back a bridged
    /// NSString, and comparing or appending to it on every call copied it through `getBytes` (a 2.7 s
    /// NIGHTLY hang in a row flush, 2026-10-29).
    private let home: String
    /// `home` followed by "/".
    private let homeFolderPrefix: String

    /// A mapping that shortens `home` (this Mac's home folder by default) to `~`.
    init(home: String = NSHomeDirectory()) {
        var native = home
        native.makeContiguousUTF8()
        self.home = native
        homeFolderPrefix = native + "/"
    }
    /// The workspace kind of the home workspace (`workspace-kind-v1`).
    public static let homeKind = "home"

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
                                workspaceFilter: (WorkspaceModel) -> Bool = { _ in true },
                                harnessIcons: @escaping () -> HarnessIconLookup = { .none }) -> [SidebarRowSection] {
        // A personal group's icon lives on the home daemon, whichever machine's section shows it.
        func groupImage(_ icon: String) -> SidebarFavicon? { groupIconAsset.map { $0(icon) } ?? iconAsset(icon) }
        var nodes: [SidebarNode] = []
        for section in daemonSections {
            // The home workspace (`kind` "home") and a window's own Home (cmux#27880) are what
            // the Home item in the top section shows; neither is also a workspace row (nxdog28)
            // while that item is in the layout (`hidesHomeWorkspace`).
            let rows = section.workspaces.filter { (!hidesHomeWorkspace || !$0.isAnyHome) && workspaceFilter($0) }
                .map { workspace in
                    let make = { row(workspace, machine: machine.id, status: statusLine(workspace.id), showsUnread: showsUnread,
                                     muted: muted.contains(workspace.id), selectedTab: selectedTab, newTabPages: newTabPages,
                                     newTabTitle: newTabTitle, pageFace: pageFace, tabTitle: tabTitle,
                                     notificationText: notificationText, iconAsset: iconAsset, harnessIcons: harnessIcons()) }
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
                    iconAsset: (String) -> SidebarFavicon? = { _ in nil },
                    harnessIcons: HarnessIconLookup = .none) -> SidebarWorkspace {
        let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
        let unread = showsUnread ? workspace.unreadCount : 0
        let statuses = StatusMapping.shared.summaries(tabs: tabs, status: workspace.status)
        let indicator = statuses.workspace
        // The focused tab; the row is named for its chat while it is an idle shell (`labelTab`).
        let focused = frontTab(workspace, selectedTab: selectedTab), front = labelTab(focused, tabs, newTabPages: newTabPages)
        // The workspace's folder (Group by Folder's bucket).
        let rowFolder = focused?.cwd ?? tabs.lazy.compactMap(\.cwd).first
        let folder = folderTab(tabs, label: front)
        // The row's face (name, icon, kind) is one tab's: the label tab, or the work a page beside
        // it was opened from (an agent's PR in its right column), wherever focus is. The page's
        // favicon stays on the page's own tab (Leo, 2026-10-21: a chat row showed GitHub's mark).
        let face = faceTab(workspace, selectedTab: selectedTab, newTabPages: newTabPages)
        let page = face.flatMap { pageFace(workspace, $0, nil) }
        // Each browser tab's face once: its favicon in the tab list, its sound on the row.
        var browserFaces: [String: PageFace] = [:]
        for tab in tabs where tab.kind == .browser {
            browserFaces[tab.id] = tab.id == face?.id ? page : pageFace(workspace, tab, nil)
        }
        let entries = workspace.status?.entries ?? []
        // Another computer's folders shorten against that computer's home, never this Mac's (cx-gaq9).
        let shorten: (String) -> String = machine == .local ? { abbreviate($0) } : Self.abbreviateRemote
        let title = Self.sidebarTitle(workspace, page: page)
        let rowAgent = agentMark(tabs, harnessIcons: harnessIcons)
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
            agentWorking: statuses.working,
            // A page in a split beside a chat or terminal leaves the row's icon to that work, as it
            // leaves its name (#22250; Leo 2026-10-21: "why did this turn into the githb favicon?").
            icon: Self.icon(color: workspace.color, icon: workspace.icon, asset: iconAsset)
                ?? page?.favicon.map(WorkspaceIcon.favicon),
            color: color(workspace.color), kind: kind(face),
            kindBrand: face?.agentBrand,
            // A tab marked unread by hand (Mark Tab Unread) or by an agent that needs the person
            // there (tab-attention-v1) shows as the workspace's manual dot.
            unread: unread > 0 ? .count(unread)
                : (showsUnread && (workspace.markedUnread || tabs.contains { $0.markedUnread || $0.attention != nil }) ? .dot : .none),
            activity: indicator.state,
            activityStyle: indicator.style,
            agentBrand: rowAgent.brand,
            agentIcon: rowAgent.icon,
            agentName: agentTab(tabs, harnessIcons: harnessIcons)?.agentName,
            progress: progress(workspace, tabs: tabs),
            tabs: zip(tabs, statuses.tabs).map { tab, state in
                let isNewTabPage = newTabPages.contains(tab.id) && !newTabTitle.isEmpty
                let title = Self.shortenedPath(tabTitle?(tab) ?? (isNewTabPage ? newTabTitle : tab.displayTitle), of: tab, shorten: shorten)
                // The hover card's tab rows show each tab's own folder and status; a New Tab page shows neither.
                var listed = SidebarTab(id: TabID(tab.id), title: title,
                                        kind: Self.listedKind(tab, newTabPages: newTabPages), isUnread: tab.showsUnread,
                                        brand: tab.agentBrand, favicon: browserFaces[tab.id]?.favicon,
                                        folder: isNewTabPage ? nil : tab.cwd.flatMap { $0.isEmpty ? nil : shorten($0) },
                                        state: isNewTabPage ? .idle : state)
                // Its chat's running subagents and commands, which the tab row counts.
                (listed.subagentsRunning, listed.commandsRunning) = Self.running(tab)
                return listed
            },
            muted: muted,
            // The store refuses every close of its home workspace (`home_not_closable`); a
            // window's own Home closes only with its window.
            isClosable: !workspace.isAnyHome,
            // Group by Folder's bucket: the front tab's folder, else any tab's.
            folder: rowFolder.map(shorten)
        )
        row.focusedTab = focused.map { TabID($0.id) }
        row.activityFromProgram = indicator.primary?.source == .program
        row.presence = presence(tabs)
        row.isUnnamed = Self.isUnnamed(workspace, label: page?.title)
        row.audio = SidebarWorkspaceAudio.merge(tabs.lazy.map { browserFaces[$0.id]?.audio })
        row.lastMessage = lastMessage(front, tabs)
        // What an agent needs the person to do in a tab says why the row is marked; it comes
        // before the newest notification's text (tab-attention-v1).
        if showsUnread { row.notificationText = Self.attentionReason(tabs) ?? newestUnread(tabs).flatMap(notificationText) }
        row.reported = Self.reported(workspace.status, asset: iconAsset)
        row.workspaceDescription = workspace.workspaceDescription
        row.taskStatus = workspace.taskStatus.map(Self.taskStatus)
        row.checklist = workspace.checklist.map(Self.checklistItem)
        row.detail = detail(tabs: tabs, indicator: indicator.state, agentTab: agentTab(tabs, harnessIcons: harnessIcons), front: front,
                            notification: row.notificationText)
        return row
    }

    /// Automatic agent names prefer the chat title, then its task gist. Explicit workspace
    /// and chat names retain their original text; the rendered row label is not naming provenance.
    public static func agentRowTitle(workspaceTitle: String, workspaceName: String? = nil,
                                    workspaceNameSource: WorkspaceNameSource = .user, workspaceNameRevision: UInt64 = 0,
                                    explicitWorkspaceTitle: String? = nil, sessionName: String?, chatTitle: String?,
                                    explicitChatTitle: String? = nil, taskSummary: String?) -> String {
        if let explicitWorkspaceTitle, !explicitWorkspaceTitle.isEmpty { return workspaceTitle }
        let originalName = workspaceName ?? workspaceTitle
        // A rename remains authoritative even when the user chose a default-looking name or
        // the session name. Revision zero also supports launcher-named workspaces.
        if workspaceNameSource == .user, workspaceNameRevision > 0 { return workspaceTitle }
        let machineNamed = workspaceNameSource == .auto || WorkspaceModel.isDefaultName(originalName)
            || originalName == sessionName || originalName == shortSessionName(sessionName)
        guard machineNamed else { return workspaceTitle }
        if let explicitChatTitle, !explicitChatTitle.isEmpty { return explicitChatTitle }
        for candidate in [chatTitle, taskSummary] {
            guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
                  value.caseInsensitiveCompare(sessionName ?? "") != .orderedSame,
                  value.caseInsensitiveCompare(shortSessionName(sessionName) ?? "") != .orderedSame else { continue }
            return value
        }
        return workspaceTitle
    }

    /// Peers qualify session names for routing; the sidebar already shows the host separately.
    public static func shortSessionName(_ name: String?) -> String? {
        name?.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init)
    }

    /// Nobody named `workspace` and nothing names it: no title, the daemon's default name, and
    /// no name from its front tab (`label`, the auto name) beyond the home folder (Leo 2026-10-20:
    /// "~", "workspace-11" and "workspace-29" rows clutter the sidebar).
    public static func isUnnamed(_ workspace: WorkspaceModel, label: String?) -> Bool {
        guard workspace.isUnnamed else { return false }
        guard let label, !label.isEmpty else { return true }
        return label == "~"
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

    /// The tab the row stands for: the selected tab of the workspace's most
    /// recently focused pane; nil for a workspace with no tabs.
    public func frontTab(_ workspace: WorkspaceModel, selectedTab: (PaneModel) -> String?) -> TabModel? {
        let panes = workspace.screens.flatMap(\.panes).filter { !$0.tabs.isEmpty }
        guard let pane = panes.max(by: { $0.focusedAt < $1.focusedAt }) else { return nil }
        return selected(pane, selectedTab: selectedTab)
    }

    /// The tab a browser front tab yields its row's name to (a PR opened in
    /// a split, https://github.com/manaflow-ai/cmux/issues/22249): the
    /// selected tab of the most recently focused pane that shows a chat or
    /// terminal, the work the row was named for before the page opened; nil
    /// while every pane shows a page. A Home, page or app tab gives no name
    /// (`WorkspaceAutoNameReader.front`), so it is passed over too.
    public func workTab(_ workspace: WorkspaceModel, selectedTab: (PaneModel) -> String?) -> TabModel? {
        // One pass: the newest eligible pane, the first stored one on a tie (as `frontTab`).
        var work: (tab: TabModel, focusedAt: UInt64)?
        for screen in workspace.screens {
            for pane in screen.panes where !pane.tabs.isEmpty {
                if let work, pane.focusedAt <= work.focusedAt { continue }
                let tab = selected(pane, selectedTab: selectedTab)
                let named = tab.agentSession != nil || (tab.kind != .conversation && tab.page == nil && tab.appTab == nil)
                if tab.kind != .browser, named { work = (tab, pane.focusedAt) }
            }
        }
        return work?.tab
    }

    /// The one tab a workspace's row and window titlebar both read their name and icon from: the
    /// label tab (`labelTab`), or for a browser one the work it yields to (`workTab`), so focus
    /// moving to a page beside a chat leaves both the chat's.
    public func faceTab(_ workspace: WorkspaceModel, selectedTab: (PaneModel) -> String?,
                        newTabPages: Set<String> = []) -> TabModel? {
        let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
        let front = labelTab(frontTab(workspace, selectedTab: selectedTab), tabs, newTabPages: newTabPages)
        guard front?.kind == .browser else { return front }
        return workTab(workspace, selectedTab: selectedTab) ?? front
    }

    /// The tab `pane` shows: the window's selection, else the daemon's default tab.
    private func selected(_ pane: PaneModel, selectedTab: (PaneModel) -> String?) -> TabModel {
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
        agentTab(tabs)?.agentBrand
    }

    /// The reason of the newest "needs you here" mark among `tabs` (tab-attention-v1).
    static func attentionReason(_ tabs: [TabModel]) -> String? {
        tabs.compactMap(\.attention).max { $0.atMs < $1.atMs }?.reason
    }

    /// The tab whose unread notification is the newest (daemon ids grow).
    func newestUnread(_ tabs: [TabModel]) -> TabModel? {
        tabs.filter(\.hasUnread).max { ($0.notification?.notification.rawValue ?? 0) < ($1.notification?.notification.rawValue ?? 0) }
    }

    /// The last message of the row's agent chat (`chatTab`).
    func lastMessage(_ front: TabModel?, _ tabs: [TabModel]) -> String? {
        chatTab(front, tabs)?.agentSession.flatMap(AgentTurnStateStore.shared.lastMessage(for:))
    }

    /// The row's agent chat, whose last message the row shows: the front tab's, else the first chat tab's.
    func chatTab(_ front: TabModel?, _ tabs: [TabModel]) -> TabModel? {
        front?.agentSession != nil ? front : tabs.first { $0.agentSession != nil }
    }

    /// The agent chat a workspace's row shows (Copy Agent Identifier on the row copies its id).
    public func rowChat(_ workspace: WorkspaceModel, selectedTab: (PaneModel) -> String?) -> TabModel? {
        chatTab(frontTab(workspace, selectedTab: selectedTab), workspace.screens.flatMap(\.panes).flatMap(\.tabs))
    }

    /// The mark the row draws for its agent tab (`agentTab`): a custom harness's own icon (user
    /// 12922; a mark it names is a brand, anything else the row's `agentIcon`), else the tab's brand.
    func agentMark(_ tabs: [TabModel], harnessIcons: HarnessIconLookup) -> (brand: String?, icon: SidebarAgentIcon?) {
        guard let tab = agentTab(tabs, harnessIcons: harnessIcons) else { return (nil, nil) }
        switch harnessIcons.custom(for: tab.agentSession?.harness) {
        case .brand(let brand)?: return (brand, nil)
        case .symbol(let name)?: return (nil, .symbol(name))
        case .image(_, let favicon)?: return (nil, .image(favicon))
        case nil: return (tab.agentBrand, nil)
        }
    }

    /// The tab whose agent the row names: a working or waiting one first. A chat on a custom
    /// harness with its own icon counts like a branded one.
    func agentTab(_ tabs: [TabModel], harnessIcons: HarnessIconLookup = .none) -> TabModel? {
        let branded = tabs.lazy.filter { $0.agentBrand != nil || harnessIcons.custom(for: $0.agentSession?.harness) != nil }
        return branded.first { $0.agent?.state == .working || $0.agent?.state == .blocked } ?? branded.first
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

    /// Status entry keys that feed their own row elements, not the status
    /// line (`cmux workspace status set ports|pr <text>`).
    public static let portsKey = "ports"
    public static let pullRequestKey = "pr"

    /// The status line: every entry but the ones other elements show.
    static func statusLine(_ entries: [WorkspaceStatus.Entry]) -> String? {
        let texts = entries.filter { $0.key != portsKey && $0.key != pullRequestKey }.map(\.text).filter { !$0.isEmpty }
        return texts.isEmpty ? nil : texts.joined(separator: " · ")
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

    static func entry(_ key: String, in entries: [WorkspaceStatus.Entry]) -> String? {
        entries.first { $0.key == key && !$0.text.isEmpty }?.text
    }

    /// The front terminal's program as the shell or program titles it (OSC
    /// 0/2); nil for other tabs, an untitled terminal, or a title that only
    /// repeats the folder.
    func process(_ tab: TabModel?) -> String? {
        guard let tab, tab.kind == .pty, tab.agent == nil else { return nil }
        let title = tab.titleText.trimmingCharacters(in: .whitespaces)
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

    /// A terminal tab titled by its own folder (an untitled shell shows its folder, `TabItemMapping.title`, and some
    /// shells title it so) reads as its prompt writes it: this Mac's home and another computer's home both as `~`.
    /// A title naming another path (a program's), a name the person gave the tab and an agent's tab stay as they are.
    /// Another computer's folder never matched this Mac's home, so a Cloud shell's tab read `/home/cmux` (Leo
    /// 2026-10-29: "why is there all this weird stuff at the bottom of the sidebar").
    static func shortenedPath(_ title: String, of tab: TabModel, shorten: (String) -> String) -> String {
        // A terminal running an agent (`tab.agent`, its hooks' report) is the agent's tab, not a shell's.
        guard tab.agentSession == nil, tab.agent == nil, tab.kind == .pty || tab.kind == .remoteTerminal, tab.name?.isEmpty ?? true,
              let cwd = tab.cwd, Self.trimmingSlash(title) == Self.trimmingSlash(cwd) else { return title }
        return shorten(Self.trimmingSlash(cwd))
    }

    private static func trimmingSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
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
        if path == home { return "~" }
        if path.hasPrefix(homeFolderPrefix) { return "~" + path.dropFirst(home.count) }
        return path
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
