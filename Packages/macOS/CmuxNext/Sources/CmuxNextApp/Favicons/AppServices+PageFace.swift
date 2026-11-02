import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar
import CmuxNextTabs
import CmuxNextWorkspaceNaming
import Foundation

extension AppServices {
    /// The favicon of browser tab `key`: its live page's icon, else the one
    /// its record names (`recordFavicon`); nil while it loads or without one.
    /// `profile`: the tab's engine profile when the caller has it (else looked up by tab).
    func browserFavicon(key: String, recordFavicon: String?, profile: BrowserProfileID? = nil) -> TabImage? {
        _ = cache.pageInstalls.generation(of: key) // this tab's page only, not every page install
        let live = cache.existingBrowser(key)?.tab
        let address = cache.pageRequests.proxiedTabs.appFetchableFavicon(
            live.map { $0.state.faviconURL?.absoluteString } ?? recordFavicon, key: key, page: live)
        return favicons.image(for: address, profile: profile ?? browserProfiles.engineProfile(forTab: key), tab: live)
    }

    /// What the sidebar row of `workspace` shows of its front tab, or a
    /// browser tab in its tab list: the page's favicon (cx-e32b), and while
    /// the workspace keeps the daemon's default name, the name the front tab
    /// gives it (hq#1957, `WorkspaceAutoName`; renaming it shows the user's name).
    /// A page beside `work` (an agent's PR in a split) keeps the name `work` gives.
    /// `tab` and `work` are tabs of `workspace`: their incognito answer is the workspace's own, and a page made or
    /// closed later is this tab's (`browserFavicon`), so a change in another workspace maps no other row (F6).
    func sidebarPageFace(_ workspace: WorkspaceModel, tab: TabModel, work: TabModel?) -> SidebarMapping.PageFace {
        let incognito = tab.kind == .browser && windows.isIncognito(workspace: workspace)
        let favicon = tab.kind != .browser ? nil : browserFavicon(key: tab.id, recordFavicon: incognito ? nil : tab.faviconURL,
                                                                   profile: browserProfiles.engineProfile(for: tab, incognito: incognito))
            .map { SidebarFavicon($0.cgImage) }
        let names = WorkspaceAutoNameWiring(services: self, workspace: workspace).reader
        let audio = tab.kind != .browser ? nil : BrowserTabAudio.rowAudio(cache.existingBrowser(tab.id)?.tab.state)
        return .init(title: names.label(workspace, front: tab, work: work), favicon: favicon, audio: audio)
    }
}
