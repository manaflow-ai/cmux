import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar
import CmuxNextTabs
import CmuxNextWorkspaceNaming
import Foundation

extension AppServices {
    /// The favicon of browser tab `key`: its live page's icon, else the one
    /// its record names (`recordFavicon`); nil while it loads or without one.
    /// `known`: the tab with its incognito answer when the caller has them (else its profile is looked up by key).
    func browserFavicon(key: String, recordFavicon: String?, known: (tab: TabModel, incognito: Bool)? = nil) -> TabImage? {
        _ = cache.pageInstalls.generation(of: key) // this tab's page only, not every page install
        let live = cache.existingBrowser(key)?.tab
        let address = cache.pageRequests.proxiedTabs.appFetchableFavicon(
            live.map { $0.state.faviconURL?.absoluteString } ?? recordFavicon, key: key, page: live)
        let profile = known.map { browserProfiles.engineProfile(for: $0.tab, incognito: $0.incognito) } ?? browserProfiles.engineProfile(forTab: key)
        return favicons.image(for: address, profile: profile, tab: live)
    }

    /// What the sidebar row of `workspace` shows of its front tab, or a
    /// browser tab in its tab list: the page's favicon (cx-e32b), and while
    /// the workspace keeps the daemon's default name, the name the front tab
    /// gives it (hq#1957, `WorkspaceAutoName`; renaming it shows the user's name).
    /// A page beside `work` (an agent's PR in a split) keeps the name `work` gives.
    /// Every read is this row's own (its workspace's incognito answer, its tab's page): no other row's change maps it (F6).
    func sidebarPageFace(_ workspace: WorkspaceModel, tab: TabModel, work: TabModel?) -> SidebarMapping.PageFace {
        let names = WorkspaceAutoNameWiring(services: self, workspace: workspace).reader
        var face = SidebarMapping.PageFace(tab: tab, of: workspace, self) ?? .init()
        face.title = names.label(workspace, front: tab, work: work)
        face.startsInCloud = cloudStartTitles.startsInCloud(tab) || cloudStartTitles.startsInCloud(workspace: workspace.id)
        return face
    }

    /// The favicon `tab` shows in `workspace`'s sidebar row and band item; nil for a tab that is not a page, and while
    /// a page's favicon loads or without one (the row then shows ``WorkspaceIcon/pagePlaceholder``).
    func sidebarPageFavicon(_ workspace: WorkspaceModel, tab: TabModel) -> SidebarFavicon? {
        guard tab.kind == .browser else { return nil }
        let incognito = windows.isIncognito(workspace: workspace)
        return browserFavicon(key: tab.id, recordFavicon: incognito ? nil : SidebarMapping.favicon(tab.faviconURL, page: tab.url),
                              known: (tab, incognito)).map { SidebarFavicon($0.cgImage) }
    }
}

extension SidebarMapping.PageFace {
    /// What `workspace`'s tab list shows of browser tab `tab`'s page, from the app's sources: its favicon, its sound and
    /// its own icon; nil for a tab that is not a page. No name of the row and no settings read: a tab that is not the
    /// row's face asks only this.
    @MainActor init?(tab: TabModel, of workspace: WorkspaceModel, _ services: AppServices) {
        guard tab.kind == .browser else { return nil }
        let live = services.cache.existingBrowser(tab.id)?.tab
        self.init(favicon: services.sidebarPageFavicon(workspace, tab: tab), audio: BrowserTabAudio.rowAudio(live?.state),
                  icon: BrowserTabIconState.pageIcon(tab.url.flatMap { URL(string: $0) }))
    }
}

extension SidebarTabParts.Unobserved {
    /// What no observation covers of `tab`'s title and favicon in the tab list of a workspace whose incognito answer
    /// is `incognito`, from the app's sources. `titles`: the strip's title rule.
    @MainActor init(_ tab: TabModel, incognito: Bool, titles: TabTitleResolver, _ services: AppServices) {
        let pages = services.cache
        let remote = tab.kind == .browser && pages.pageRequests.proxiedTabs.faviconIsRemote(key: tab.id, page: pages.existingBrowser(tab.id)?.tab)
        self.init(incognito: incognito, title: titles.unobservedTitle(tab, incognito: incognito), remoteFavicon: remote)
    }
}

extension SidebarTabParts {
    /// One window's holder with the app's sources: a kept part asks its page (`SidebarMapping.PageFace.init(tab:of:_:)`)
    /// when it is made, and its row compares what no observation covers at each map (the workspace's incognito answer
    /// is one read for a map), so the part is made again for another answer.
    convenience init(_ services: AppServices) {
        let titles = TabTitleResolver(services: services)
        self.init(page: { [weak services] workspace, tab in services.flatMap { SidebarMapping.PageFace(tab: tab, of: workspace, $0) } }, given: { [weak services] workspace in
            let incognito = services?.windows.isIncognito(workspace: workspace) ?? false
            return { tab in services.map { Unobserved(tab, incognito: incognito, titles: titles, $0) } ?? Unobserved(incognito: incognito) }
        })
    }
}
