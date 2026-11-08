public import CmuxNextDaemon
import CmuxNextDesign
public import CmuxNextSidebar
import Foundation
import os

/// When the face rules could not read a batch: no row of it is remapped (`SidebarRowFeed` keeps each row's last
/// mapped one), and this says so.
private let faceLog = Logger(subsystem: "com.cmuxterm.app.next", category: "sidebar.face")

/// Every sidebar row is mapped here: its face (which tab names it, its folder, process, status line, kinds, unread
/// mark, folder bucket, notice, agent and chat tabs, the tab list's titles and kinds) from the Rust rules
/// (`SidebarFaceBatch`, `cmux_sidebar_face_rows`), every changed row of a pass in one call, then the row assembled
/// from it. What the rules do not cover stays here: the page face, the status merge (`StatusMapping`), icons,
/// presence, sound, the chat's turn facts and the hover card's detail.
extension SidebarMapping {
    /// One row of a batch: what `row` takes per workspace.
    struct FaceRowRequest {
        var workspace: WorkspaceModel
        var status: String?
        var muted = false
        var newTabPages: Set<String> = []
    }

    /// What every row of a batch shares: what `row` takes beyond the workspace (`sections` and `row` document each).
    struct FaceOptions {
        var machine: MachineID
        var showsUnread = true
        var selectedTab: (PaneModel) -> String? = { _ in nil }
        var newTabTitle = ""
        var pageFace: (WorkspaceModel, TabModel, TabModel?) -> PageFace? = { _, _, _ in nil }
        var tabTitle: ((WorkspaceModel, TabModel) -> String)?
        var notificationText: (TabModel) -> String? = { _ in nil }
        var iconAsset: (String) -> SidebarFavicon? = { _ in nil }
        /// Read per row as it stages (a row's own observation covers it).
        var harnessIcons: () -> HarnessIconLookup = { .none }
        var homeShellTitle: String?
        var foldersLabel = false
        /// The face rules' buffers to reuse (`sections(faces:)`); nil: the batch takes its own.
        var faces: SidebarFaceBatch?
    }

    /// The rows of one `sections` call (or one `faceRows`) as a ``SidebarRowBatch``: each row stages into the
    /// `SidebarFaceBatch` buffers (the window's, reused), one Rust call answers every face, each row finishes from its own.
    final class FaceRowBatch: SidebarRowBatch {
        private let mapping: SidebarMapping
        let options: FaceOptions
        private var requests: [FaceRowRequest] = []
        private var icons: [HarnessIconLookup] = []
        private var replies: [(face: SidebarFace, tabs: [TabModel], listTitles: [String])] = []
        /// The buffers between `begin` and `run`: the options' (made with the mapping's home), unless another batch
        /// holds them (a row mapped while another batch stages); else a batch of its own.
        private var faces: SidebarFaceBatch?

        init(mapping: SidebarMapping, options: FaceOptions) {
            self.mapping = mapping
            self.options = options
        }

        func begin() {
            requests.removeAll(keepingCapacity: true)
            icons.removeAll(keepingCapacity: true)
            replies.removeAll(keepingCapacity: true)
            let batch = options.faces.flatMap { $0.inUse || !$0.home.elementsEqual(mapping.home.utf8) ? nil : $0 }
                ?? SidebarFaceBatch(home: mapping.home)
            batch.inUse = true
            batch.reset(showsUnread: options.showsUnread, newTabTitled: !options.newTabTitle.isEmpty)
            faces = batch
        }

        /// Adds `request`'s row and returns its slot.
        func stage(_ request: FaceRowRequest) -> Int {
            let icons = options.harnessIcons(), workspace = request.workspace, newTabPages = request.newTabPages
            let newTabTitle = options.newTabTitle, tabTitle = options.tabTitle
            faces?.append(workspace, local: options.machine == .local, status: request.status, selectedTab: options.selectedTab,
                          newTabPages: newTabPages,
                          listTitle: { SidebarMapping.listTitle($0, of: workspace, newTabPages: newTabPages, newTabTitle: newTabTitle, tabTitle: tabTitle) },
                          branded: { $0.agentBrand != nil || icons.custom(for: $0.agentSession?.harness) != nil })
            requests.append(request)
            self.icons.append(icons)
            return requests.count - 1
        }

        func run() -> Bool {
            guard let faces else { return false }
            defer {
                faces.inUse = false
                self.faces = nil
            }
            let count = faces.count
            guard let decoded = faces.run().map({ reply in (0 ..< count).map { reply.face($0, tabCount: faces.tabRange($0).count) } }) else {
                faceLog.error("sidebar face rules could not read a batch of \(count, privacy: .public) rows; their rows keep their last mapping")
                return false
            }
            replies = decoded.enumerated().map { index, face in
                let range = faces.tabRange(index)
                return (face, Array(faces.tabs[range]), Array(faces.listTitles[range]))
            }
            return true
        }

        /// The row in `slot`, from the batch's reply.
        func finish(_ slot: Int) -> SidebarWorkspace {
            guard requests.indices.contains(slot) else { return SidebarWorkspace(id: SidebarWorkspaceID(""), machineID: options.machine, title: "") }
            guard replies.indices.contains(slot), icons.indices.contains(slot) else {
                return SidebarMapping.unmapped(requests[slot].workspace, machine: options.machine)
            }
            let reply = replies[slot]
            return mapping.faceRow(requests[slot], face: reply.face, tabs: reply.tabs, listTitles: reply.listTitles,
                                   harnessIcons: icons[slot], options: options)
        }

        /// The row of `workspace` as a feed's make: staged into this batch, finished from its reply.
        func make(_ request: @escaping () -> FaceRowRequest) -> SidebarRowFeed.Make {
            SidebarRowFeed.Make(batch: self, stage: { self.stage(request()) }, finish: { self.finish($0) })
        }
    }

    /// A row of `workspace` with nothing mapped (the face rules could not read its batch): its name, no face.
    public static func unmapped(_ workspace: WorkspaceModel, machine: MachineID) -> SidebarWorkspace {
        SidebarWorkspace(id: SidebarWorkspaceID(workspace.id), machineID: machine, title: workspace.displayName)
    }

    /// The tab list's title of `tab` before a folder title is shortened.
    static func listTitle(_ tab: TabModel, of workspace: WorkspaceModel, newTabPages: Set<String>, newTabTitle: String,
                          tabTitle: ((WorkspaceModel, TabModel) -> String)?) -> String {
        if let tabTitle { return tabTitle(workspace, tab) }
        return newTabPages.contains(tab.id) && !newTabTitle.isEmpty ? newTabTitle : tab.displayTitle
    }

    /// The rows of `requests`, their faces from one Rust call; nil when the rules could not read the batch.
    func faceRows(_ requests: [FaceRowRequest], options: FaceOptions) -> [SidebarWorkspace]? {
        let batch = FaceRowBatch(mapping: self, options: options)
        batch.begin()
        let slots = requests.map(batch.stage)
        guard batch.run() else { return nil }
        return slots.map(batch.finish)
    }

    /// One row from its face: the row's assembly, reading the face's tabs and texts.
    func faceRow(_ request: FaceRowRequest, face facts: SidebarFace, tabs: [TabModel], listTitles: [String],
                 harnessIcons: HarnessIconLookup, options: FaceOptions) -> SidebarWorkspace {
        let workspace = request.workspace, newTabPages = request.newTabPages, machine = options.machine
        func at(_ index: Int?) -> TabModel? { index.flatMap { tabs.indices.contains($0) ? tabs[$0] : nil } }
        let statuses = StatusMapping.shared.summaries(tabs: tabs, status: workspace.status)
        let indicator = statuses.workspace
        // The focused tab; the label tab the row is named for (a chat over an idle shell); the face tab (the
        // label, or the work a page beside it was opened from) whose name, icon and kind the row shows.
        let focused = at(facts.front), front = at(facts.label), folder = at(facts.folderTab), face = at(facts.face)
        let page = face.flatMap { options.pageFace(workspace, $0, nil) }
        // Each browser tab's face once: its favicon in the tab list, its sound on the row. The page's favicon
        // stays on the page's own tab (Leo, 2026-10-21: a chat row showed GitHub's mark).
        var browserFaces: [String: PageFace] = [:]
        for tab in tabs where tab.kind == .browser {
            browserFaces[tab.id] = tab.id == face?.id ? page : options.pageFace(workspace, tab, nil)
        }
        let entries = workspace.status?.entries ?? []
        func entry(_ index: Int?) -> String? { index.flatMap { entries.indices.contains($0) ? entries[$0].text : nil } }
        // An unnamed Cloud workspace whose shell idles at its home reads "Terminal" (`homeShellTitle`), its header
        // naming the machine (Leo 2026-10-30: "JUST DEPICT IT SIMILARLY TO EVERYTHING ELSE"). A caller whose
        // `pageFace` gives no title (a pinned tile) has its shell's folder read as the label.
        let label = options.foldersLabel ? face?.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } : page?.title
        let title = Self.homeShellName(options.homeShellTitle, workspace: workspace, label: label, face: face)
            ?? Self.sidebarTitle(workspace, page: page)
        let agentTab = at(facts.agent)
        let rowAgent = Self.agentMark(agentTab, harnessIcons: harnessIcons)
        var row = SidebarWorkspace(
            id: SidebarWorkspaceID(workspace.id),
            machineID: machine,
            // An older Chief's subagent workspaces show their task title, never the subagent id.
            title: machine.isLocalChief ? title.chiefTaskTitle ?? title : title,
            directory: facts.directory,
            branch: folder?.gitBranch.flatMap { $0.isEmpty ? nil : $0 },
            process: facts.process,
            status: facts.statusLine,
            ports: entry(facts.ports),
            pullRequest: entry(facts.pullRequest),
            lastActivity: facts.lastActivityMs == 0 ? nil : Self.date(ms: facts.lastActivityMs),
            rowKind: facts.rowKind,
            agentWorking: statuses.working,
            // A page in a split beside a chat or terminal leaves the row's icon to that work (#22250). A site with
            // no favicon (none, or not loaded yet) keeps the slot with a globe the favicon replaces.
            icon: Self.icon(color: workspace.color, icon: workspace.icon, asset: options.iconAsset)
                ?? page?.favicon.map(WorkspaceIcon.favicon)
                ?? (Self.isSite(face, newTabPages: newTabPages) ? .pagePlaceholder : nil),
            color: color(workspace.color), kind: facts.kind,
            kindBrand: face?.agentBrand,
            unread: facts.unread == 2 ? .count(workspace.unreadCount) : facts.unread == 1 ? .dot : .none,
            activity: indicator.state,
            activityStyle: indicator.style,
            agentBrand: rowAgent.brand,
            agentIcon: rowAgent.icon,
            agentName: agentTab?.agentName,
            progress: facts.progress,
            tabs: zip(tabs, statuses.tabs).enumerated().map { index, pair in
                let (tab, state) = pair
                let listed = facts.listed.indices.contains(index) ? facts.listed[index] : nil
                let blank = listed?.blank ?? false
                let listTitle = listTitles.indices.contains(index) ? listTitles[index] : tab.displayTitle
                let kind: SidebarTabKind = switch listed?.kind {
                case 1?: .newTab
                case 2?: .agentChat
                default: Self.tabKind(tab.kind)
                }
                // The hover card's tab rows show each tab's own folder and status; a New Tab page shows neither.
                var item = SidebarTab(id: TabID(tab.id), title: listed?.title ?? listTitle,
                                      kind: kind, isUnread: tab.showsUnread,
                                      brand: tab.agentBrand, favicon: browserFaces[tab.id]?.favicon,
                                      folder: listed?.folder,
                                      state: blank ? .idle : state,
                                      host: blank || tab.kind != .browser ? nil : Self.pageHost(tab.url),
                                      branch: tab.gitBranch.flatMap { $0.isEmpty ? nil : $0 },
                                      lastActivity: (listed?.lastActivityMs ?? 0) == 0 ? nil : Self.date(ms: listed?.lastActivityMs ?? 0))
                // Its chat's running subagents and commands, which the tab row counts.
                (item.subagentsRunning, item.commandsRunning) = Self.running(tab)
                item.isFreed = tab.kind == .pty && tab.dead && tab.relaunch?.onShow == true
                // What the tab row's line says beyond its folder (Leo 2026-11-01: "not much metadata").
                if !blank { Self.listedFacts(&item, of: tab, process: process(tab)) }
                return item
            },
            muted: request.muted,
            // The store refuses every close of its home workspace (`home_not_closable`); a
            // window's own Home closes only with its window.
            isClosable: !workspace.isAnyHome,
            folder: facts.bucket
        )
        row.focusedTab = focused.map { TabID($0.id) }
        row.activityFromProgram = indicator.primary?.source == .program
        row.presence = presence(tabs)
        row.isUnnamed = Self.isUnnamed(workspace, label: page?.title)
        row.audio = SidebarWorkspaceAudio.merge(tabs.lazy.map { browserFaces[$0.id]?.audio })
        row.lastMessage = at(facts.chat)?.agentSession.flatMap(AgentTurnStateStore.shared.lastMessage(for:))
        // What an agent needs the person to do in a tab says why the row is marked; it comes
        // before the newest notification's text (tab-attention-v1).
        if options.showsUnread {
            row.notificationText = switch facts.notice {
            case .attention(let index)?: at(index)?.attention?.reason
            case .notification(let index)?: at(index).flatMap(options.notificationText)
            case nil: nil
            }
        }
        row.reported = Self.reported(workspace.status, asset: options.iconAsset)
        row.workspaceDescription = workspace.workspaceDescription
        row.taskStatus = workspace.taskStatus.map(Self.taskStatus)
        row.checklist = workspace.checklist.map(Self.checklistItem)
        row.detail = detail(tabs: tabs, indicator: indicator.state, agentTab: agentTab, front: front,
                            notification: row.notificationText)
        return row
    }

    /// The mark the row draws for the agent tab the face picked: a custom harness's own icon (user 12922; a mark
    /// it names is a brand, anything else the row's `agentIcon`), else the tab's brand.
    static func agentMark(_ tab: TabModel?, harnessIcons: HarnessIconLookup) -> (brand: String?, icon: SidebarAgentIcon?) {
        guard let tab else { return (nil, nil) }
        switch harnessIcons.custom(for: tab.agentSession?.harness) {
        case .brand(let brand)?: return (brand, nil)
        case .symbol(let name)?: return (nil, .symbol(name))
        case .image(_, let favicon)?: return (nil, .image(favicon))
        case nil: return (tab.agentBrand, nil)
        }
    }
}
