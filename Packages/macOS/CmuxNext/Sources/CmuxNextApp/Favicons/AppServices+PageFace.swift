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
    func sidebarPageFace(_ workspace: WorkspaceModel, tab: TabModel, work: TabModel?) -> SidebarMapping.PageFace {
        let incognito = tab.kind == .browser && cache.browserTabs.isIncognitoTab(tab.id)
        let favicon = tab.kind != .browser ? nil
            : browserFavicon(key: tab.id, recordFavicon: incognito ? nil : SidebarMapping.favicon(tab.faviconURL, page: tab.url)).map { SidebarFavicon($0.cgImage) }
        let names = WorkspaceAutoNameWiring(services: self).reader
        // The media hub's tab list version: a page made or closed later maps the row again.
        if tab.kind == .browser { _ = cache.pageRequests.media.tabsVersion }
        let audio = tab.kind != .browser ? nil : BrowserTabAudio.rowAudio(cache.existingBrowser(tab.id)?.tab.state)
        return .init(title: names.label(workspace, front: tab, work: work), favicon: favicon, audio: audio)
    }
}
