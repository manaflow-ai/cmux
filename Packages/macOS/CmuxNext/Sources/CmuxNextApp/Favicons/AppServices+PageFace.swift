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
    func sidebarPageFace(_ workspace: WorkspaceModel, tab: TabModel) -> SidebarMapping.PageFace {
        let incognito = tab.kind == .browser && cache.browserTabs.isIncognitoTab(tab.id)
        let favicon = tab.kind != .browser ? nil
            : browserFavicon(key: tab.id, recordFavicon: incognito ? nil : tab.faviconURL).map { SidebarFavicon($0.cgImage) }
        let names = WorkspaceAutoNameWiring(services: self).reader
        // A page beside an agent chat or terminal keeps the workspace named
        // for that work, not for the page (a PR opened in a right split).
        let anchor: WorkspaceAutoName.Front? = tab.kind != .browser ? nil : {
            let others = workspace.screens.flatMap(\.panes).flatMap(\.tabs).filter { $0.kind != .browser }
            let fronts = others.compactMap { names.front($0) }
            return fronts.first { if case .chat = $0 { true } else { false } }
                ?? fronts.first { if case .terminal = $0 { true } else { false } }
        }()
        return .init(title: names.rule.label(name: workspace.name, title: workspace.title, front: names.front(tab), anchor: anchor),
                     favicon: favicon)
    }
}
