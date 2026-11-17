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
    let home: String
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
    static func sidebarTitle(_ workspace: WorkspaceModel, page: PageFace?) -> String {
        if let pageTitle = page?.title, !pageTitle.isEmpty { return pageTitle }
        return workspace.displayName
    }

    /// Whether `label` is only the last folder of an account's home (`/home/cmux` read "cmux"): what an idle shell at
    /// another computer's home gives its workspace, the account's name, not the work. Only a shell's: a tab the person
    /// named, a chat, a terminal running an agent, or one whose shell or program set its own title (OSC 0/2) keeps a
    /// label that happens to be that word. A title that is only the folder's path or the shell's name (`zsh`) is the
    /// shell saying where it is.
    static func namesHome(_ label: String?, tab: TabModel?) -> Bool {
        guard let label, let tab, let cwd = tab.cwd.map(Self.trimmingSlash), abbreviateRemote(cwd) == "~",
              tab.kind == .pty || tab.kind == .remoteTerminal, tab.name?.isEmpty ?? true,
              tab.titleText.isEmpty || TerminalTitle.isBareShell(tab.titleText) || Self.trimmingSlash(tab.titleText) == cwd,
              tab.agent == nil, tab.agentSession == nil else { return false }
        return label == URL(fileURLWithPath: cwd).lastPathComponent || Self.trimmingSlash(label) == cwd
    }

    /// `title` when `workspace` is unnamed and `label`, the name its face tab `face` gives it, is only its shell's home
    /// (`namesHome`), else nil: the one rule the sidebar row and the titlebar, palette and rename prompt
    /// (`WorkspaceAutoNameReader.titlebarName`) both read, so a Cloud home shell reads "Terminal" on all of them.
    public static func homeShellName(_ title: String?, workspace: WorkspaceModel, label: String?, face: TabModel?) -> String? {
        title.flatMap { workspace.isUnnamed && namesHome(label, tab: face) ? $0 : nil }
    }
    /// Supplies a row in place of mapping it now: the workspace, its machine, and the mapping to run later (a row of
    /// the pass's face batch: the feed maps every row it remaps in a turn in one call).
    public typealias RowSource = (WorkspaceModel, MachineID, SidebarRowFeed.Make) -> SidebarWorkspace
    /// Answers whether a workspace lists in place of running its rule in the structural pass (``SidebarRowFeed/lists(_:rule:)``).
    public typealias ListingSource = (WorkspaceModel, @escaping () -> Bool) -> Bool

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
    /// titled `newTabTitle` (localized by the App); `isNewTabPage`, when given,
    /// names them per row instead, read by the row's own mapping (so a page
    /// opened in one workspace maps that row only). `pageFace` gives the face
    /// a workspace's front tab (any kind) lends its row, given the work tab a
    /// browser front tab yields its name to (`FaceTabs.work`), and the favicon of
    /// each browser tab in the tab list (no work tab). `tabTitle` names each tab in the tab
    /// list as its strip does (the App's `TabTitleResolver`, given the row's workspace); without it a
    /// tab shows its record's title. `iconAsset` draws a stored image or SVG
    /// icon (`image:` / `svg:sha256-<hex>`); nil while it loads.
    /// `rowSource`, when given, supplies each row instead of mapping it here:
    /// it gets the workspace and the mapping to run later (`SidebarRowFeed`),
    /// so a structural pass reads no row's status. Every row of one call is in one face batch
    /// (`FaceRowBatch`): the feed maps the ones it remaps together, in one Rust call; without a source
    /// every listed row maps here in one call. `faces` are the face rules' buffers the batch reuses (a window's
    /// sidebar keeps one across passes); without them it takes its own.
    /// `workspaceFilter` drops workspaces that are no longer valid sidebar rows
    /// (for example, an acpmux session that was purged while its tab lingers).
    /// `listing`, when given, answers whether each workspace lists (the Home rule and `workspaceFilter`) from its own
    /// observation, so the pass reads no workspace's tabs (`SidebarRowFeed`).
    /// `terminalTitle` (localized by the App) names a Cloud machine's unnamed workspace whose shell idles at its home.
    public func sections(_ daemonSections: [DaemonSidebarSection], machine: SidebarMachine,
                                collapsedGroups: Set<String> = [],
                                hidesHomeWorkspace: Bool = true,
                                showsUnread: Bool = true,
                                muted: Set<String> = [],
                                statusLine: @escaping (String) -> String? = { _ in nil },
                                selectedTab: @escaping (PaneModel) -> String? = { _ in nil },
                                focusedPane: @escaping (WorkspaceModel) -> String? = { _ in nil },
                                newTabPages: Set<String> = [], isNewTabPage: ((WorkspaceModel, TabModel) -> Bool)? = nil, newTabTitle: String = "",
                                pageFace: @escaping (WorkspaceModel, TabModel, TabModel?) -> PageFace? = { _, _, _ in nil },
                                tabTitle: ((WorkspaceModel, TabModel) -> String)? = nil, notificationText: @escaping (TabModel) -> String? = { _ in nil },
                                iconAsset: @escaping (String) -> SidebarFavicon? = { _ in nil },
                                groupIconAsset: ((String) -> SidebarFavicon?)? = nil,
                                rowSource: RowSource? = nil,
                                listing: ListingSource? = nil,
                                workspaceFilter: @escaping (WorkspaceModel) -> Bool = { _ in true },
                                terminalTitle: String? = nil,
                                harnessIcons: @escaping () -> HarnessIconLookup = { .none }, faces: SidebarFaceBatch? = nil) -> [SidebarRowSection] {
        // A personal group's icon lives on the home daemon, whichever machine's section shows it.
        func groupImage(_ icon: String) -> SidebarFavicon? { groupIconAsset.map { $0(icon) } ?? iconAsset(icon) }
        let batch = FaceRowBatch(mapping: self, options: FaceOptions(
            machine: machine.id, showsUnread: showsUnread, selectedTab: selectedTab, focusedPane: focusedPane,
            newTabTitle: newTabTitle, pageFace: pageFace,
            tabTitle: tabTitle, notificationText: notificationText, iconAsset: iconAsset, harnessIcons: harnessIcons,
            homeShellTitle: machine.kind == .cloud ? terminalTitle : nil, faces: faces))
        // The home workspace (`kind` "home") and a window's own Home (cmux#27880) are what
        // the Home item in the top section shows; neither is also a workspace row (nxdog28)
        // while that item is in the layout (`hidesHomeWorkspace`).
        let listed = daemonSections.map { section in
            section.workspaces.filter { workspace in
                let lists = { (!hidesHomeWorkspace || !workspace.isAnyHome) && workspaceFilter(workspace) }
                return listing?(workspace, lists) ?? lists()
            }
        }
        let workspaces = Array(listed.joined())
        let makes = workspaces.map { workspace in
            batch.make {
                FaceRowRequest(workspace: workspace, status: statusLine(workspace.id), muted: muted.contains(workspace.id),
                               newTabPages: isNewTabPage.map { Self.newTabPages(of: workspace, $0) } ?? newTabPages)
            }
        }
        let mapped = rowSource.map { source in zip(workspaces, makes).map { source($0, machine.id, $1) } }
            ?? zip(workspaces, SidebarRowFeed.Make.rows(makes)).map { $1 ?? Self.unmapped($0, machine: machine.id) }
        var rest = mapped[...]
        var nodes: [SidebarNode] = []
        for (section, members) in zip(daemonSections, listed) {
            let rows = Array(rest.prefix(members.count))
            rest = rest.dropFirst(members.count)
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

    /// The tabs of `workspace` that `isPage` calls New Tab pages.
    static func newTabPages(of workspace: WorkspaceModel, _ isPage: (WorkspaceModel, TabModel) -> Bool) -> Set<String> {
        Set(workspace.screens.flatMap(\.panes).flatMap(\.tabs).filter { isPage(workspace, $0) }.map(\.id))
    }

    /// `showsUnread: false` hides the unread badge (`notifications.attention.showOnSidebar`).
    /// `selectedTab` is the window's tab selection in a pane (a `TabModel.id`), nil for the
    /// daemon's default tab. `focusedPane` is the pane id the window last focused in the workspace,
    /// nil for the daemon's most recently focused one. `newTabPages` are the ids of tabs still on the New Tab page,
    /// listed as `newTabTitle` when it is not empty.
    /// `muted`: the workspace is in `notifications.mutedWorkspaces`. `notificationText` is the
    /// text of a tab's unread notification (`DaemonStore.notificationText(for:)`).
    /// `iconAsset` draws a stored image or SVG icon, as in `sections`.
    /// `homeShellTitle` titles an unnamed workspace whose shell idles at its home (a Cloud machine's, `sections`).
    /// `foldersLabel`: a caller whose `pageFace` gives no title (a pinned tile, `SidebarWorkspaceItems`) has its shell's
    /// folder read as the label `homeShellTitle` checks; the list's rows read the label their `pageFace` gives.
    public func row(_ workspace: WorkspaceModel, machine: MachineID, status: String? = nil, showsUnread: Bool = true,
                    muted: Bool = false, selectedTab: @escaping (PaneModel) -> String? = { _ in nil },
                    focusedPane: @escaping (WorkspaceModel) -> String? = { _ in nil }, newTabPages: Set<String> = [],
                    newTabTitle: String = "", pageFace: @escaping (WorkspaceModel, TabModel, TabModel?) -> PageFace? = { _, _, _ in nil },
                    tabTitle: ((WorkspaceModel, TabModel) -> String)? = nil, notificationText: @escaping (TabModel) -> String? = { _ in nil },
                    iconAsset: @escaping (String) -> SidebarFavicon? = { _ in nil },
                    harnessIcons: HarnessIconLookup = .none, homeShellTitle: String? = nil, foldersLabel: Bool = false) -> SidebarWorkspace {
        let options = FaceOptions(machine: machine, showsUnread: showsUnread, selectedTab: selectedTab, focusedPane: focusedPane,
                                  newTabTitle: newTabTitle,
                                  pageFace: pageFace, tabTitle: tabTitle, notificationText: notificationText, iconAsset: iconAsset,
                                  harnessIcons: { harnessIcons }, homeShellTitle: homeShellTitle, foldersLabel: foldersLabel)
        let request = FaceRowRequest(workspace: workspace, status: status, muted: muted, newTabPages: newTabPages)
        return faceRows([request], options: options)?.first ?? Self.unmapped(workspace, machine: machine)
    }

    /// `row` of each workspace (in order), each machine's in one face batch: a pinned tile's rows. `homeShellTitle` as
    /// in `row`, per machine; `faces` as in `sections`.
    public func rows(_ workspaces: [(workspace: WorkspaceModel, machine: MachineID)], showsUnread: Bool = true,
                     pageFace: @escaping (WorkspaceModel, TabModel, TabModel?) -> PageFace? = { _, _, _ in nil },
                     homeShellTitle: (MachineID) -> String? = { _ in nil }, foldersLabel: Bool = false,
                     faces: SidebarFaceBatch? = nil) -> [SidebarWorkspace] {
        var byMachine: [MachineID: [Int]] = [:], machines: [MachineID] = []
        for (index, item) in workspaces.enumerated() {
            if byMachine[item.machine] == nil { machines.append(item.machine) }
            byMachine[item.machine, default: []].append(index)
        }
        var rows = workspaces.map { Self.unmapped($0.workspace, machine: $0.machine) }
        for machine in machines {
            let members = byMachine[machine] ?? []
            let options = FaceOptions(machine: machine, showsUnread: showsUnread, pageFace: pageFace, homeShellTitle: homeShellTitle(machine),
                                      foldersLabel: foldersLabel, faces: faces)
            let mapped = faceRows(members.map { FaceRowRequest(workspace: workspaces[$0].workspace) }, options: options) ?? []
            for (index, row) in zip(members, mapped) { rows[index] = row }
        }
        return rows
    }

    /// The band items (pinned tiles, top rows) of `workspaces`, in order: each row as `rows` maps it with `pageFace`,
    /// the face the list's rows read (`AppServices.sidebarPageFace`), no unread state and its shell's folder as the label.
    /// Pinning moves a row and never renames it: an item shows the title its list row shows, the workspace's own name
    /// or the auto name the face gives one nobody named (Lawrence 2026-11-07: "i pinned a workspace and it's name
    /// disappeared and went back to workspace-936"; the favicon-only face it read fell back to the daemon's name).
    public func tileInfos(_ workspaces: [(workspace: WorkspaceModel, machine: MachineID)],
                          pageFace: @escaping (WorkspaceModel, TabModel, TabModel?) -> PageFace,
                          homeShellTitle: (MachineID) -> String?, faces: SidebarFaceBatch? = nil) -> [SidebarItemInfo] {
        let mapped = self.rows(workspaces, showsUnread: false, pageFace: pageFace,
                               homeShellTitle: homeShellTitle, foldersLabel: true, faces: faces)
        return zip(workspaces, mapped).map { item, row in
            var info = SidebarItemInfo(workspaceRow: row, color: color(item.workspace.color))
            info.activity = row.activity
            info.activityStyle = row.activityStyle
            (info.workspace, info.workspaceRow) = (row.id, row) // the row's hover card reads `workspaceRow`
            return info
        }
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

    /// The row's agent chat as Copy Agent Identifier reads it: the front tab's, else the first chat tab's. The
    /// front tab comes from the Rust face (`faceTabs`); this pick stays in Swift only until the face answers it
    /// too (`front_chat`, cmux-layout-reducer `sidebar_face`), then it goes.
    func chatTab(_ front: TabModel?, _ tabs: [TabModel]) -> TabModel? {
        front?.agentSession != nil ? front : tabs.first { $0.agentSession != nil }
    }

    /// The agent chat a workspace's row shows (Copy Agent Identifier on the row copies its id).
    public func rowChat(_ workspace: WorkspaceModel, selectedTab: (PaneModel) -> String?) -> TabModel? {
        chatTab(frontTab(workspace, selectedTab: selectedTab), workspace.screens.flatMap(\.panes).flatMap(\.tabs))
    }

    static func tabKind(_ kind: TabKind) -> SidebarTabKind {
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

    /// Whether `tab` is a site page (a browser tab on a host, not a New Tab page): the tabs that show a favicon.
    static func isSite(_ tab: TabModel?, newTabPages: Set<String>) -> Bool {
        guard let tab, tab.kind == .browser, !newTabPages.contains(tab.id) else { return false }
        return pageHost(tab.url) != nil
    }

    /// A page's host for the hover card's tab rows ("github.com"); nil for a blank or local page.
    static func pageHost(_ url: String?) -> String? {
        guard let url, let host = URL(string: url)?.host(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
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

    /// This feed as the mapping's listing source (`SidebarMapping.sections(listing:)`).
    public var listingSource: SidebarMapping.ListingSource {
        { workspace, rule in self.lists(SidebarWorkspaceID(workspace.id), rule: rule) }
    }
}
