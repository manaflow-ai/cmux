public import CmuxNextDaemon
public import CmuxNextSidebar
public import CmuxNextDesign
import CCmuxLayoutReducerFFI
import Foundation

/// Maps the daemon store's sidebar flattening into sidebar rows: one machine
/// section per daemon, its sections in order (loose runs and groups, which
/// may interleave with `personal-mixed-order-v1`).
public struct SidebarMapping {
    public static let shared = Self()
    /// The face rules (Rust, through `SidebarFaceFFI`): this Mac's home folder is read once there.
    private let rules: SidebarFaceFFI
    /// This Mac's home folder as a native string, read once: `NSHomeDirectory()` hands back a bridged
    /// NSString, and comparing or appending to it on every call copied it through `getBytes` (a 2.7 s
    /// NIGHTLY hang in a row flush, 2026-10-29).
    private let home: String
    /// `home` followed by "/".
    private let homeFolderPrefix: String

    /// A mapping that shortens `home` (this Mac's home folder by default) to `~`.
    init(home: String = NSHomeDirectory()) {
        rules = home == NSHomeDirectory() ? .shared : SidebarFaceFFI(home: home)
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
    /// list as its strip does (the App's `TabTitleResolver`, given the row's workspace); without it a
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
                                tabTitle: ((WorkspaceModel, TabModel) -> String)? = nil, notificationText: @escaping (TabModel) -> String? = { _ in nil },
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
                    color: color(group.color) ?? .grey,
                    // A custom `#RRGGBB` (cx-25az) or no color (`none`) draws instead of the token. No stored color, or one
                    // this Mac cannot read, is no color: a group shows a color only when a person picked one
                    // (Leo 2026-10-31: "WHERE IS ORANGE COMING FROM").
                    custom: color(group.color) != nil ? nil : (group.color.flatMap { GroupTint(wire: $0)?.wire } ?? GroupTint.noneWire),
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
                    tabTitle: ((WorkspaceModel, TabModel) -> String)? = nil, notificationText: (TabModel) -> String? = { _ in nil },
                    iconAsset: (String) -> SidebarFavicon? = { _ in nil },
                    harnessIcons: HarnessIconLookup = .none) -> SidebarWorkspace {
        let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
        let statuses = StatusMapping.shared.summaries(tabs: tabs, status: workspace.status)
        let indicator = statuses.workspace
        // The face rules run in Rust (cmux-layout-reducer `sidebar_face`, through `SidebarFaceFFI`): which tab the row
        // stands for and is named for, its folder, kinds, program, status line, unread mark, notice, progress and each
        // listed tab's title and folder. Another computer's folders shorten against that computer's home (cx-gaq9).
        let listTitles = tabs.map { tab in
            tabTitle?(workspace, tab) ?? (newTabPages.contains(tab.id) && !newTabTitle.isEmpty ? newTabTitle : tab.displayTitle)
        }
        let facts = rules.face(workspace, local: machine == .local, status: status, showsUnread: showsUnread,
                               newTabPages: newTabPages, newTabTitled: !newTabTitle.isEmpty, listTitles: listTitles,
                               selectedTab: selectedTab, branded: {
                                   $0.agentBrand != nil || harnessIcons.custom(for: $0.agentSession?.harness) != nil
                               }) ?? SidebarFaceFFI.Face()
        let fact = facts.row
        func tabAt(_ index: UInt32) -> TabModel? { facts.index(index).flatMap { tabs.indices.contains($0) ? tabs[$0] : nil } }
        let focused = tabAt(fact.front), front = tabAt(fact.label), face = tabAt(fact.face), agent = tabAt(fact.agent)
        let entries = workspace.status?.entries ?? []
        func entry(_ index: UInt32) -> String? { facts.index(index).flatMap { entries.indices.contains($0) ? entries[$0].text : nil } }
        // The row's face (name, icon, kind) is one tab's: the label tab, or the work a page beside
        // it was opened from (an agent's PR in its right column), wherever focus is. The page's
        // favicon stays on the page's own tab (Leo, 2026-10-21: a chat row showed GitHub's mark).
        let page = face.flatMap { pageFace(workspace, $0, nil) }
        // Each browser tab's face once: its favicon in the tab list, its sound on the row.
        var browserFaces: [String: PageFace] = [:]
        for tab in tabs where tab.kind == .browser {
            browserFaces[tab.id] = tab.id == face?.id ? page : pageFace(workspace, tab, nil)
        }
        let title = Self.sidebarTitle(workspace, page: page)
        let rowAgent = agentMark(agent, harnessIcons: harnessIcons)
        let folder = tabAt(fact.folder_tab)
        var row = SidebarWorkspace(
            id: SidebarWorkspaceID(workspace.id),
            machineID: machine,
            // An older Chief's subagent workspaces show their task title, never the subagent id.
            title: machine.isLocalChief ? title.chiefTaskTitle ?? title : title,
            directory: facts.text(fact.directory),
            branch: folder?.gitBranch.flatMap { $0.isEmpty ? nil : $0 },
            process: facts.text(fact.process),
            // The hooks' status line, else the daemon's workspace status
            // (state resources) without the entries other elements show.
            status: facts.text(fact.status_line),
            ports: entry(fact.ports),
            pullRequest: entry(fact.pull_request),
            lastActivity: Self.date(nonZeroMs: fact.last_activity_ms),
            rowKind: Self.rowKind(fact.row_kind),
            agentWorking: statuses.working,
            // A page in a split beside a chat or terminal leaves the row's icon to that work, as it
            // leaves its name (#22250; Leo 2026-10-21: "why did this turn into the githb favicon?").
            icon: Self.icon(color: workspace.color, icon: workspace.icon, asset: iconAsset)
                ?? page?.favicon.map(WorkspaceIcon.favicon),
            color: color(workspace.color), kind: Self.kind(fact.kind),
            kindBrand: face?.agentBrand,
            // A tab marked unread by hand (Mark Tab Unread) or by an agent that needs the person
            // there (tab-attention-v1) shows as the workspace's manual dot.
            unread: fact.unread == 2 ? .count(workspace.unreadCount) : fact.unread == 1 ? .dot : .none,
            activity: indicator.state,
            activityStyle: indicator.style,
            agentBrand: rowAgent.brand,
            agentIcon: rowAgent.icon,
            agentName: agent?.agentName,
            progress: fact.progress == 0 ? nil : SidebarProgress(value: fact.progress_value.isNaN ? nil : fact.progress_value,
                                                                 isError: fact.progress_error != 0),
            tabs: zip(tabs, statuses.tabs).enumerated().map { index, pair in
                let (tab, state) = pair
                let listed = facts.listed(index)
                let blank = (listed?.flags ?? 0) & 2 != 0
                // The hover card's tab rows show each tab's own folder and status; a New Tab page shows neither.
                let title = listed.flatMap { $0.flags & 1 != 0 ? facts.text($0.title) : nil } ?? listTitles[index]
                var item = SidebarTab(id: TabID(tab.id), title: title,
                                      kind: Self.listedKind(listed?.kind, tab), isUnread: tab.showsUnread,
                                      brand: tab.agentBrand, favicon: browserFaces[tab.id]?.favicon,
                                      folder: listed.flatMap { facts.text($0.folder) },
                                      state: blank ? .idle : state,
                                      host: blank || tab.kind != .browser ? nil : Self.pageHost(tab.url),
                                      branch: tab.gitBranch.flatMap { $0.isEmpty ? nil : $0 },
                                      lastActivity: Self.date(nonZeroMs: listed?.last_activity_ms ?? 0))
                // Its chat's running subagents and commands, which the tab row counts.
                (item.subagentsRunning, item.commandsRunning) = Self.running(tab)
                // What the tab row's line says beyond its folder (Leo 2026-11-01: "not much metadata"):
                // a page's path, a chat's model, a terminal's running program, a remote terminal's machine.
                if !blank { Self.listedFacts(&item, of: tab, process: process(tab)) }
                return item
            },
            muted: muted,
            // The store refuses every close of its home workspace (`home_not_closable`); a
            // window's own Home closes only with its window.
            isClosable: !workspace.isAnyHome,
            // Group by Folder's bucket: the front tab's folder, else any tab's.
            folder: facts.text(fact.bucket)
        )
        row.focusedTab = focused.map { TabID($0.id) }
        row.activityFromProgram = indicator.primary?.source == .program
        row.presence = presence(tabs)
        row.isUnnamed = Self.isUnnamed(workspace, label: page?.title)
        row.audio = SidebarWorkspaceAudio.merge(tabs.lazy.map { browserFaces[$0.id]?.audio })
        row.lastMessage = tabAt(fact.chat)?.agentSession.flatMap(AgentTurnStateStore.shared.lastMessage(for:))
        // What an agent needs the person to do in a tab says why the row is marked; it comes
        // before the newest notification's text (tab-attention-v1).
        if showsUnread {
            row.notificationText = switch fact.notice {
            case 1: tabAt(fact.notice_tab)?.attention?.reason
            case 2: tabAt(fact.notice_tab).flatMap(notificationText)
            default: nil
            }
        }
        row.reported = Self.reported(workspace.status, kept: facts.keptEntries, asset: iconAsset)
        row.workspaceDescription = workspace.workspaceDescription
        row.taskStatus = workspace.taskStatus.map(Self.taskStatus)
        row.checklist = workspace.checklist.map(Self.checklistItem)
        row.detail = detail(tabs: tabs, indicator: indicator.state, agentTab: agent, front: front,
                            process: facts.text(fact.process), notification: row.notificationText)
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

    /// The tab the row stands for: the selected tab of the workspace's most recently focused pane;
    /// nil for a workspace with no tabs (the face rules, `SidebarFaceFFI`).
    public func frontTab(_ workspace: WorkspaceModel, selectedTab: (PaneModel) -> String?) -> TabModel? {
        faceTab(workspace, selectedTab: selectedTab, newTabPages: [], level: .front, pick: \.front)
    }

    /// The tab a browser front tab yields its row's name to (a PR opened in a split,
    /// https://github.com/manaflow-ai/cmux/issues/22249): the selected tab of the most recently
    /// focused pane that shows a chat or terminal; nil while every pane shows a page. A Home, page or
    /// app tab gives no name (`WorkspaceAutoNameReader.front`), so it is passed over too.
    public func workTab(_ workspace: WorkspaceModel, selectedTab: (PaneModel) -> String?) -> TabModel? {
        faceTab(workspace, selectedTab: selectedTab, newTabPages: [], level: .work, pick: \.work)
    }

    /// The one tab a workspace's row and window titlebar both read their name and icon from: the
    /// label tab (`labelTab`), or for a browser one the work it yields to (`workTab`), so focus
    /// moving to a page beside a chat leaves both the chat's.
    public func faceTab(_ workspace: WorkspaceModel, selectedTab: (PaneModel) -> String?,
                        newTabPages: Set<String> = []) -> TabModel? {
        faceTab(workspace, selectedTab: selectedTab, newTabPages: newTabPages, level: .face, pick: \.face)
    }

    /// The tab of `workspace` the face rules pick at `pick`. `level` encodes only what that rule reads, so an
    /// observing caller (the auto-namer, a window's titlebar) is not woken by a tab's progress, notification or
    /// agent report (O(changed), not every tab event of every workspace).
    private func faceTab(_ workspace: WorkspaceModel, selectedTab: (PaneModel) -> String?, newTabPages: Set<String>,
                         level: SidebarFaceFFI.Level, pick: KeyPath<CmuxSidebarFaceRow, UInt32>) -> TabModel? {
        guard let facts = rules.face(workspace, level: level, local: true, status: nil, showsUnread: true, newTabPages: newTabPages,
                                     newTabTitled: false, listTitles: [], selectedTab: selectedTab, branded: { _ in false }),
              let index = facts.index(facts.row[keyPath: pick]) else { return nil }
        let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
        return tabs.indices.contains(index) ? tabs[index] : nil
    }

    /// The agent chat a workspace's row shows (Copy Agent Identifier on the row copies its id): the label tab's chat,
    /// so with an idle shell in front, the chat the row is named for.
    public func rowChat(_ workspace: WorkspaceModel, selectedTab: (PaneModel) -> String?) -> TabModel? {
        faceTab(workspace, selectedTab: selectedTab, newTabPages: [], level: .face, pick: \.chat)
    }

    /// The face rules' row kind code (0 terminal, 1 browser, 2 harness) as the sidebar draws it.
    static func kind(_ code: UInt8) -> SidebarWorkspaceKind {
        switch code {
        case 2: .harness
        case 1: .browser
        default: .terminal
        }
    }

    /// The face rules' code for what the tabs are (0 terminal, 1 browser, 2 agent, 3 mixed).
    static func rowKind(_ code: UInt8) -> WorkspaceRowKind {
        switch code {
        case 1: .browser
        case 2: .agent
        case 3: .mixed
        default: .terminal
        }
    }

    /// Milliseconds since 1970 as a date; nil for 0.
    static func date(nonZeroMs ms: UInt64) -> Date? { ms == 0 ? nil : date(ms: ms) }

    /// The mark the row draws for its agent tab (`agentTab`): a custom harness's own icon (user
    /// 12922; a mark it names is a brand, anything else the row's `agentIcon`), else the tab's brand.
    func agentMark(_ tab: TabModel?, harnessIcons: HarnessIconLookup) -> (brand: String?, icon: SidebarAgentIcon?) {
        guard let tab else { return (nil, nil) }
        switch harnessIcons.custom(for: tab.agentSession?.harness) {
        case .brand(let brand)?: return (brand, nil)
        case .symbol(let name)?: return (nil, .symbol(name))
        case .image(_, let favicon)?: return (nil, .image(favicon))
        case nil: return (tab.agentBrand, nil)
        }
    }

    /// A tab's kind in the tab list: a New Tab page, an agent chat, else its record's kind.
    /// The face rules' listed kind code (0 the record's kind, 1 new tab, 2 agent chat).
    private static func listedKind(_ code: UInt8?, _ tab: TabModel) -> SidebarTabKind {
        switch code {
        case 1?: .newTab
        case 2?: .agentChat
        default: tabKind(tab.kind)
        }
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

    /// The status block: every entry but the ones other elements show, the
    /// newest log line and the progress label; nil when none is reported. `asset` draws an
    /// entry's stored image or SVG icon.
    /// `kept` are the indexes of the entries the block lists (the face rules' status entries).
    static func reported(_ status: WorkspaceStatus?, kept: [Int],
                         asset: (String) -> SidebarFavicon? = { _ in nil }) -> SidebarWorkspaceStatus? {
        guard let status else { return nil }
        let block = SidebarWorkspaceStatus(
            entries: kept.compactMap { status.entries.indices.contains($0) ? status.entries[$0] : nil }.map {
                SidebarWorkspaceStatus.Entry(key: $0.key, text: $0.text, icon: $0.icon, tint: SidebarWorkspaceStatus.Tint($0.color), state: $0.state,
                                             image: $0.icon.flatMap(asset))
            },
            log: status.lastLog.map {
                SidebarWorkspaceStatus.LogLine(level: SidebarWorkspaceStatus.LogLevel(rawValue: $0.level) ?? .info, text: $0.text)
            },
            progressLabel: status.progress?.label)
        return block.isEmpty ? nil : block
    }

    /// A terminal tab's program as the shell or program titles it (OSC 0/2); nil for other tabs, an untitled
    /// terminal, or a title that only repeats the folder. The row's own program comes from the Rust face
    /// (`sidebar_face::process`); this copy serves only the hover card's per-tab line (`listedFacts`), which the
    /// face's C reply does not carry per tab yet (follow-up: a listed-tab program field in the next FFI step A).
    func process(_ tab: TabModel?) -> String? {
        guard let tab, tab.kind == .pty, tab.agent == nil else { return nil }
        let title = tab.titleText.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        if let cwd = tab.cwd, title == cwd || title == abbreviate(cwd) { return nil }
        return title
    }

    /// The hover card tab row's facts beyond its folder and state, from the tab's own records.
    static func listedFacts(_ listed: inout SidebarTab, of tab: TabModel, process: String?, turns: AgentTurnStateStore = .shared) {
        if tab.kind == .browser { listed.path = pagePath(tab.url) }
        listed.model = tab.agentSession.flatMap(turns.detail(for:))?.model.flatMap { $0.isEmpty ? nil : $0 }
        if commandStart(tab) != nil { listed.command = process }
        if let remote = tab.remote, !remote.sessionName.isEmpty { listed.machine = remote.sessionName }
    }

    /// A page's path for the hover card's tab rows ("/manaflow-ai/cmux/pull/12"), without its query or
    /// fragment; nil for a root or blank page.
    static func pagePath(_ url: String?) -> String? {
        guard let url, let components = URLComponents(string: url), components.host?.isEmpty == false else { return nil }
        var path = components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty || path == "/" ? nil : path
    }

    /// The site's own icon address ("https://github.com/favicon.ico") for a page whose record names no
    /// favicon (a restored tab never loaded); nil for a page that is not http(s), and for a loopback page,
    /// whose icon may belong to another machine's forwarded port (never guessed onto this Mac's).
    public static func siteFavicon(_ url: String?) -> String? {
        guard let url, let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host?.lowercased(), !host.isEmpty,
              !isLoopback(host) else { return nil }
        var site = URLComponents()
        site.scheme = scheme
        site.host = host
        site.port = components.port
        site.path = "/favicon.ico"
        return site.string
    }

    /// A page's favicon address: the one its record names, else the site's own (`siteFavicon`), so a restored
    /// page that never loaded shows its site and not a bare globe (Leo 2026-11-01: "there's no symbols").
    public static func favicon(_ recorded: String?, page url: String?) -> String? {
        recorded.flatMap { $0.isEmpty ? nil : $0 } ?? siteFavicon(url)
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost") || host.hasPrefix("127.") || host == "[::1]" || host == "::1" || host == "0.0.0.0"
    }

    /// A page's host for the hover card's tab rows ("github.com"); nil for a blank or local page.
    static func pageHost(_ url: String?) -> String? {
        guard let url, let host = URL(string: url)?.host(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// A folder of this Mac with its home folder as `~`, for the tab strip, hover card and screen bar, which map one
    /// tab per call: it stays in Swift until those callers map a pane's tabs in one batched Rust call (the row map
    /// already uses the Rust rule, `sidebar_face::abbreviate`, inside the face).
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
