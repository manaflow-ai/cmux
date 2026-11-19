import CmuxNextCompat
public import CmuxNextDaemon
import CmuxNextSidebar

/// What a window's sidebar keeps of its rows' tabs from map to map: one part for each tab of each row
/// (``KeptParts``), and the app's two functions that a part asks.
///
/// A row's map reads each of its tabs. A row that maps again as a whole at each change of one tab makes each
/// tab's title, facts, status and item again: the work of one tab made or closed grows with the workspace. With
/// this, a tab that comes or changes makes its own part, and the row joins the kept parts of its other tabs.
///
/// A part is made again when something that its map read changes. What its map reads and can not observe is the
/// part's input, read for each tab at each map of the row: whether the tab is on the New Tab page, whether its
/// chat's harness has its own icon, and what `given` answers (``Unobserved``).
///
/// One window's sidebar has one of these and gives it to `SidebarMapping.sections(tabs:)` at each pass. A caller
/// with none (a pinned tile, one row) has each part made at each map.
public final class SidebarTabParts {
    /// A browser tab's favicon, sound and own icon for the tab list: no title, and no read of the row's name.
    public typealias Page = (WorkspaceModel, TabModel) -> SidebarMapping.PageFace?
    /// What the app gives for each tab of a workspace. The outer call is made one time for a row's map. The inner
    /// call gets the tab and the answer of the row's page rule for it (the tab is in the row's New Tab page set), so
    /// the app does not ask its rule a second time; nil where the row has no page rule (its set is the caller's ids).
    public typealias Given = (WorkspaceModel) -> (TabModel, _ newTabPage: Bool?) -> Unobserved

    /// What the app gives for one tab at each map of its row: the values that decide the tab's title or favicon and
    /// that no observation covers. A kept part whose value is another one is made again, and its map then asks the
    /// row's title and page functions again, so the row shows their answer of that map.
    public nonisolated struct Unobserved: Equatable, Sendable {
        /// The tab's workspace is incognito.
        public var incognito: Bool
        /// The tab's title where a source that is not observable decides it; nil for each other tab.
        public var title: String?
        /// The tab's favicon is of a store of another machine (the app does not fetch a loopback address of it).
        public var remoteFavicon: Bool

        public init(incognito: Bool = false, title: String? = nil, remoteFavicon: Bool = false) {
            self.incognito = incognito
            self.title = title
            self.remoteFavicon = remoteFavicon
        }
    }

    /// What a tab's part is made with and can not observe.
    nonisolated struct Input: Equatable, Sendable {
        /// The tab is in the row's New Tab page set.
        var newTabPage: Bool
        /// The tab's chat's harness has its own icon.
        var customIcon: Bool
        var given: Unobserved?
    }

    /// One tab's part of its sidebar row: what the row's map makes from the tab alone.
    struct Part {
        /// What the face rules read of the tab, with the tab list's title.
        var facts: SidebarFaceBatch.TabFacts
        var status: StatusMapping.TabShare
        /// A browser tab's page (its favicon, sound and own icon); nil for each other tab.
        var page: SidebarMapping.PageFace?
        /// The tab list's item where the rules list the tab with its own facts. The row sets its title, kind,
        /// folder and last activity from the rules' reply.
        var item: SidebarTab
        /// The item where the rules list the tab blank (a New Tab page): no state, no host and no facts.
        var blankItem: SidebarTab
    }

    let kept = KeptParts<WorkspaceModel, TabModel, Part>(step: "SidebarMapping.tabItems")
    let page: Page?
    let given: Given?

    /// - Parameters:
    ///   - page: A browser tab's page in the tab list; nil: the row's `pageFace` answers.
    ///   - given: What no observation covers of a tab's title and favicon; nil: nothing.
    public init(page: Page? = nil, given: Given? = nil) {
        self.page = page
        self.given = given
    }

    /// The parts of the tabs of `request`'s workspace, in pane order (the order of the face's tab indexes): kept
    /// ones from `options.tabs`, and one made now for each tab that is new or whose part read something that
    /// changed. With no `options.tabs` each part is made now.
    static func parts(_ request: SidebarMapping.FaceRowRequest, icons: HarnessIconLookup, options: SidebarMapping.FaceOptions,
                      mapping: SidebarMapping) -> [Part] {
        let workspace = request.workspace, newTabPages = request.newTabPages, source = options.tabs
        let given = source?.given?(workspace)
        let tabs = workspace.screens.flatMap { $0.panes.flatMap(\.tabs) }
        if source == nil { ObservationWork.visited(tabs.count, "SidebarMapping.tabItems") }
        return KeptParts<WorkspaceModel, TabModel, Part>.parts(of: workspace, tabs, kept: source?.kept, input: { tab in
            let newTabPage = newTabPages.contains(tab.id)
            return Input(newTabPage: newTabPage, customIcon: icons.custom(for: tab.agentSession?.harness) != nil,
                         given: given?(tab, request.pagesByRule ? newTabPage : nil))
        }, make: { (tab: TabModel, input: Input) -> Part in
            let listTitle = SidebarMapping.listTitle(tab, of: workspace, newTabPages: input.newTabPage ? [tab.id] : [],
                                                     newTabTitle: options.newTabTitle, tabTitle: options.tabTitle)
            let status = StatusMapping.shared.share(of: tab)
            var page: SidebarMapping.PageFace?
            if tab.kind == .browser {
                if let ask = source?.page { page = ask(workspace, tab) } else { page = options.pageFace(workspace, tab, nil) }
            }
            var blank = SidebarTab(id: TabID(tab.id), title: listTitle, kind: SidebarMapping.tabKind(tab.kind), isUnread: tab.showsUnread,
                                   brand: tab.agentBrand, favicon: page?.favicon,
                                   branch: tab.gitBranch.flatMap { $0.isEmpty ? nil : $0 })
            blank.pageIcon = page?.icon
            // Its chat's running subagents and commands, which the tab row counts.
            (blank.subagentsRunning, blank.commandsRunning) = SidebarMapping.running(tab)
            blank.isFreed = tab.kind == .pty && tab.dead && tab.relaunch?.onShow == true
            var item = blank
            item.state = status.state
            item.host = tab.kind != .browser ? nil : SidebarMapping.pageHost(tab.url)
            // What the tab row's line says beyond its folder.
            SidebarMapping.listedFacts(&item, of: tab, process: mapping.process(tab))
            let facts = SidebarFaceBatch.facts(tab, newTabPage: input.newTabPage, listTitle: listTitle,
                                               branded: tab.agentBrand != nil || input.customIcon)
            return Part(facts: facts, status: status, page: page, item: item, blankItem: blank)
        })
    }
}
