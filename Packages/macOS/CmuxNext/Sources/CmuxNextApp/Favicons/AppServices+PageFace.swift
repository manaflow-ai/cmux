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
        let favicon = sidebarPageFavicon(workspace, tab: tab)
        let names = WorkspaceAutoNameWiring(services: self, workspace: workspace).reader
        let audio = tab.kind != .browser ? nil : BrowserTabAudio.rowAudio(cache.existingBrowser(tab.id)?.tab.state)
        return .init(title: names.label(workspace, front: tab, work: work), favicon: favicon, audio: audio)
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
