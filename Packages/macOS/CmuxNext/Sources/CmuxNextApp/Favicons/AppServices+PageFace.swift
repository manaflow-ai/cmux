import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar
import CmuxNextTabs
import CmuxNextWorkspaceNaming
import Foundation

extension AppServices {
    /// The favicon of browser tab `key`: its live page's icon, else the one
    /// its record names (`recordFavicon`); nil while it loads or without one.
    func browserFavicon(key: String, recordFavicon: String?) -> TabImage? {
        _ = cache.pageInstalls.revision
        let live = cache.existingBrowser(key)?.tab
        let address = cache.pageRequests.proxiedTabs.appFetchableFavicon(
            live.map { $0.state.faviconURL?.absoluteString } ?? recordFavicon, key: key, page: live)
        return favicons.image(for: address, profile: browserProfiles.engineProfile(forTab: key), tab: live)
    }

    /// What the sidebar row of `workspace` shows of its front tab, or a
    /// browser tab in its tab list: the page's favicon (cx-e32b), and while
    /// the workspace keeps the daemon's default name, the name the front tab
    /// gives it (hq#1957, `WorkspaceAutoName`; renaming it shows the user's name).
    /// A page beside `work` (an agent's PR in a split) keeps the name `work` gives.
    ///
    /// `tab` and `work` are tabs of `workspace`. Every read here is this row's own: the workspace's incognito answer
    /// (not a lookup of each tab's workspace, which reads every daemon's tab list and workspace list) and this tab's
    /// page (`PageInstallCounter.generation(of:)`, not the count of every page). One tab made, closed or moved, or one
    /// page made, in another workspace maps no other row again (TYPING UNDER LOAD F6).
    func sidebarPageFace(_ workspace: WorkspaceModel, tab: TabModel, work: TabModel?) -> SidebarMapping.PageFace {
        let incognito = tab.kind == .browser && windows.isIncognito(workspace: workspace)
        let favicon = tab.kind != .browser ? nil : browserFavicon(tab: tab, incognito: incognito).map { SidebarFavicon($0.cgImage) }
        let names = WorkspaceAutoNameWiring(services: self, workspace: workspace).reader
        // This tab's page made or closed later maps the row again (`browserFavicon` reads it too).
        let audio = tab.kind != .browser ? nil : BrowserTabAudio.rowAudio(cache.existingBrowser(tab.id)?.tab.state)
        return .init(title: names.label(workspace, front: tab, work: work), favicon: favicon, audio: audio)
    }

    /// `browserFavicon(key:recordFavicon:)` for browser tab `tab` whose incognito answer the caller has (its
    /// workspace's): observes this tab's page only, never every page install, and asks the tab's profile without
    /// looking up its workspace.
    func browserFavicon(tab: TabModel, incognito: Bool) -> TabImage? {
        let key = tab.id
        _ = cache.pageInstalls.generation(of: key)
        let live = cache.existingBrowser(key)?.tab
        let address = cache.pageRequests.proxiedTabs.appFetchableFavicon(
            live.map { $0.state.faviconURL?.absoluteString } ?? (incognito ? nil : tab.faviconURL), key: key, page: live)
        return favicons.image(for: address, profile: browserProfiles.engineProfile(for: tab, incognito: incognito), tab: live)
    }
}
