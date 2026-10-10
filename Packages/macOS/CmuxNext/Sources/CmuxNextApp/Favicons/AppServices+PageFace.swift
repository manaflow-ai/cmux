import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar
import CmuxNextTabs
import Foundation

extension AppServices {
    /// The favicon of browser tab `key`: its live page's icon, else the one
    /// its record names (`recordFavicon`); nil while it loads or without one.
    func browserFavicon(key: String, recordFavicon: String?) -> TabImage? {
        _ = cache.pageInstalls.revision
        let live = cache.existingBrowser(key)?.tab
        let address = cache.pageRequests.proxiedTabs.appFetchableFavicon(
            live.map { $0.state.faviconURL?.absoluteString } ?? recordFavicon, key: key, page: live)
        return favicons.image(for: address, profile: browserProfiles.engineProfile(forTab: key))
    }

    /// What the sidebar row of `workspace` shows of its front browser tab
    /// (cx-e32b): the page's favicon, and its title while the workspace
    /// keeps the daemon's default name (renaming it shows the user's name).
    func sidebarPageFace(_ workspace: WorkspaceModel, tab: TabModel) -> SidebarMapping.PageFace {
        let incognito = cache.browserTabs.isIncognitoTab(tab.id)
        let favicon = browserFavicon(key: tab.id, recordFavicon: incognito ? nil : tab.faviconURL).map { SidebarFavicon($0.cgImage) }
        let named = (workspace.title.map { !$0.isEmpty } ?? false) || !NewWorkspaceName.isDefaultWorkspaceName(workspace.name)
        guard !named else { return .init(favicon: favicon) }
        if incognito { return .init(title: cache.incognitoDisplay(tab).title, favicon: favicon) }
        return .init(title: pageTitle(tab), favicon: favicon)
    }

    /// A browser tab's title as a workspace name: the tab's user name, else
    /// its page title (live, else recorded) unless it only repeats the
    /// address, else its host without `www.` (`NewWorkspaceName.forTab`).
    private func pageTitle(_ tab: TabModel) -> String? {
        func clean(_ text: String?) -> String? {
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        if let name = clean(tab.name) { return name }
        let page = cache.existingBrowser(tab.id)?.tab.state
        let url = page?.url ?? tab.url.flatMap(URL.init(string:))
        for candidate in [page?.title, tab.title] {
            guard let title = clean(candidate), title != clean(url?.absoluteString), title != clean(tab.url) else { continue }
            return title
        }
        return url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
    }
}
