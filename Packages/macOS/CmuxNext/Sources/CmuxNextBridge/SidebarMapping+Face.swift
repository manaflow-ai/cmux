import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar
import Foundation

/// `row(_:machine:...)` with its face from the Rust rules (`SidebarFaceBatch`): every changed row of a
/// frame in one call. What the rules do not cover stays here, unchanged: the page face, the status merge
/// (`StatusMapping`), icons, presence, sound, the chat's turn facts and the hover card's detail. No caller
/// uses it yet; `SidebarFaceCostTests` measures it against `row` and checks the two agree.
extension SidebarMapping {
    /// One row of a batch: what `row` takes per workspace.
    struct FaceRowRequest {
        var workspace: WorkspaceModel
        var status: String?
        var muted = false
        var newTabPages: Set<String> = []
    }

    /// The tab list's title of `tab`, as `row` gives it before a folder title is shortened.
    static func listTitle(_ tab: TabModel, of workspace: WorkspaceModel, newTabPages: Set<String>, newTabTitle: String,
                          tabTitle: ((WorkspaceModel, TabModel) -> String)?) -> String {
        if let tabTitle { return tabTitle(workspace, tab) }
        return newTabPages.contains(tab.id) && !newTabTitle.isEmpty ? newTabTitle : tab.displayTitle
    }

    /// Fills `batch` with `requests` (the encode step of ``faceRows``).
    func encodeFaces(_ requests: [FaceRowRequest], into batch: SidebarFaceBatch, machine: MachineID, showsUnread: Bool,
                     selectedTab: (PaneModel) -> String?, newTabTitle: String,
                     tabTitle: ((WorkspaceModel, TabModel) -> String)?, harnessIcons: HarnessIconLookup) {
        batch.reset(showsUnread: showsUnread, newTabTitled: !newTabTitle.isEmpty)
        let local = machine == .local
        for request in requests {
            let workspace = request.workspace, newTabPages = request.newTabPages
            batch.append(workspace, local: local, status: request.status, selectedTab: selectedTab, newTabPages: newTabPages,
                         listTitle: { Self.listTitle($0, of: workspace, newTabPages: newTabPages, newTabTitle: newTabTitle, tabTitle: tabTitle) },
                         branded: { $0.agentBrand != nil || harnessIcons.custom(for: $0.agentSession?.harness) != nil })
        }
    }

    /// Every row of `batch` (filled by ``encodeFaces``) decoded from one call; nil when the rules could not read it.
    func decodeFaces(_ batch: SidebarFaceBatch) -> [SidebarFace]? {
        guard let reply = batch.run() else { return nil }
        return (0 ..< batch.count).map { reply.face($0, tabCount: batch.tabRange($0).count) }
    }

    /// The rows of `requests`, as `row` maps each with the same arguments, their faces from one Rust call.
    func faceRows(_ requests: [FaceRowRequest], batch: SidebarFaceBatch, machine: MachineID, showsUnread: Bool = true,
                  selectedTab: (PaneModel) -> String? = { _ in nil }, newTabTitle: String = "",
                  pageFace: (WorkspaceModel, TabModel, TabModel?) -> PageFace? = { _, _, _ in nil },
                  tabTitle: ((WorkspaceModel, TabModel) -> String)? = nil, notificationText: (TabModel) -> String? = { _ in nil },
                  iconAsset: (String) -> SidebarFavicon? = { _ in nil }, harnessIcons: HarnessIconLookup = .none,
                  homeShellTitle: String? = nil) -> [SidebarWorkspace]? {
        encodeFaces(requests, into: batch, machine: machine, showsUnread: showsUnread, selectedTab: selectedTab,
                    newTabTitle: newTabTitle, tabTitle: tabTitle, harnessIcons: harnessIcons)
        guard let faces = decodeFaces(batch) else { return nil }
        return requests.indices.map { index in
            let range = batch.tabRange(index)
            return faceRow(requests[index], face: faces[index], tabs: Array(batch.tabs[range]), listTitles: Array(batch.listTitles[range]),
                           machine: machine, showsUnread: showsUnread, newTabTitle: newTabTitle, pageFace: pageFace,
                           notificationText: notificationText, iconAsset: iconAsset, harnessIcons: harnessIcons,
                           homeShellTitle: homeShellTitle)
        }
    }

    /// One row from its face: `row`'s assembly, reading the face's tabs and texts in place of its own rules.
    func faceRow(_ request: FaceRowRequest, face facts: SidebarFace, tabs: [TabModel], listTitles: [String], machine: MachineID,
                 showsUnread: Bool, newTabTitle: String, pageFace: (WorkspaceModel, TabModel, TabModel?) -> PageFace?,
                 notificationText: (TabModel) -> String?, iconAsset: (String) -> SidebarFavicon?,
                 harnessIcons: HarnessIconLookup, homeShellTitle: String?) -> SidebarWorkspace {
        let workspace = request.workspace, newTabPages = request.newTabPages
        func at(_ index: Int?) -> TabModel? { index.flatMap { tabs.indices.contains($0) ? tabs[$0] : nil } }
        let statuses = StatusMapping.shared.summaries(tabs: tabs, status: workspace.status)
        let indicator = statuses.workspace
        let focused = at(facts.front), front = at(facts.label), folder = at(facts.folderTab), face = at(facts.face)
        let page = face.flatMap { pageFace(workspace, $0, nil) }
        var browserFaces: [String: PageFace] = [:]
        for tab in tabs where tab.kind == .browser {
            browserFaces[tab.id] = tab.id == face?.id ? page : pageFace(workspace, tab, nil)
        }
        let entries = workspace.status?.entries ?? []
        func entry(_ index: Int?) -> String? { index.flatMap { entries.indices.contains($0) ? entries[$0].text : nil } }
        let title = Self.homeShellName(homeShellTitle, workspace: workspace, label: page?.title, face: face)
            ?? Self.sidebarTitle(workspace, page: page)
        let agentTab = at(facts.agent)
        let rowAgent = Self.agentMark(agentTab, harnessIcons: harnessIcons)
        var row = SidebarWorkspace(
            id: SidebarWorkspaceID(workspace.id),
            machineID: machine,
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
            icon: Self.icon(color: workspace.color, icon: workspace.icon, asset: iconAsset)
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
                var item = SidebarTab(id: TabID(tab.id), title: listed?.title ?? listTitle,
                                      kind: kind, isUnread: tab.showsUnread,
                                      brand: tab.agentBrand, favicon: browserFaces[tab.id]?.favicon,
                                      folder: listed?.folder,
                                      state: blank ? .idle : state,
                                      host: blank || tab.kind != .browser ? nil : Self.pageHost(tab.url),
                                      branch: tab.gitBranch.flatMap { $0.isEmpty ? nil : $0 },
                                      lastActivity: (listed?.lastActivityMs ?? 0) == 0 ? nil : Self.date(ms: listed?.lastActivityMs ?? 0))
                (item.subagentsRunning, item.commandsRunning) = Self.running(tab)
                item.isFreed = tab.kind == .pty && tab.dead && tab.relaunch?.onShow == true
                if !blank { Self.listedFacts(&item, of: tab, process: process(tab)) }
                return item
            },
            muted: request.muted,
            isClosable: !workspace.isAnyHome,
            folder: facts.bucket
        )
        row.focusedTab = focused.map { TabID($0.id) }
        row.activityFromProgram = indicator.primary?.source == .program
        row.presence = presence(tabs)
        row.isUnnamed = Self.isUnnamed(workspace, label: page?.title)
        row.audio = SidebarWorkspaceAudio.merge(tabs.lazy.map { browserFaces[$0.id]?.audio })
        row.lastMessage = at(facts.chat)?.agentSession.flatMap(AgentTurnStateStore.shared.lastMessage(for:))
        if showsUnread {
            row.notificationText = switch facts.notice {
            case .attention(let index)?: at(index)?.attention?.reason
            case .notification(let index)?: at(index).flatMap(notificationText)
            case nil: nil
            }
        }
        row.reported = Self.reported(workspace.status, asset: iconAsset)
        row.workspaceDescription = workspace.workspaceDescription
        row.taskStatus = workspace.taskStatus.map(Self.taskStatus)
        row.checklist = workspace.checklist.map(Self.checklistItem)
        row.detail = detail(tabs: tabs, indicator: indicator.state, agentTab: agentTab, front: front,
                            notification: row.notificationText)
        return row
    }

    /// `agentMark` for the agent tab the face picked.
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
