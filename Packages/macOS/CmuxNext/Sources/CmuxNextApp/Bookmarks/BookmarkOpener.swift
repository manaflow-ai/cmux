import AppKit
import CmuxNextBookmarks
import CmuxNextBrowser
import CmuxNextHistory
import Foundation

/// Opens bookmarks: one path for the bar, the manager page, the palette,
/// the omnibar edit bubble and the CLI. A bookmark opens in the tab it was
/// clicked from (else the focused browser tab), or in a new tab of that pane.
@MainActor
struct BookmarkOpener {
    let services: AppServices

    /// `fromTab` is the tab whose bar or page asked; nil means the focused pane.
    func open(_ node: BookmarkNode, profile: String, disposition: BookmarkOpenDisposition, fromTab key: String? = nil) {
        guard let url = node.url else { return }
        services.bookmarks.touch(node.id, profile: profile)
        open(url, profile: profile, disposition: disposition, fromTab: key)
    }

    func open(_ url: URL, profile: String, disposition requested: BookmarkOpenDisposition, fromTab key: String? = nil) {
        // From a top page (Bookmarks on top): open in the window's workspace, in a new tab.
        let disposition = TopPages.leave(services) && requested == .currentTab ? .newTab : requested
        let pane = key.flatMap { services.paneShowing(tab: $0) } ?? services.windows.active?.focusedPane
        guard let pane else { return services.registry.refuse(RefusalStrings.noWindowOpen) }
        if disposition == .currentTab, let tab = key.flatMap({ services.cache.tabModel($0) }) ?? pane.selectedTab, tab.kind == .browser,
           let entry = services.cache.existingBrowser(tab.id) {
            if entry.state.loadOverride?(url) == true { return }
            entry.tab.load(url)
            return
        }
        pane.newBrowserTab(url: url, background: disposition == .backgroundTab, profile: profile)
    }

    /// Every bookmark directly in `folder`, each in a new tab (Open All), as the daemon has them now.
    func openAll(in folder: String, profile: String, fromTab key: String? = nil) async throws {
        open(try await links(in: folder, profile: profile), profile: profile, fromTab: key)
    }

    /// The links directly in `folder`, read from the home daemon.
    func links(in folder: String, profile: String) async throws -> [BookmarkNode] {
        try await services.bookmarks.routed.children(of: folder, profile: profile, limit: 20_000).filter { !$0.isFolder }
    }

    /// `links` each in a new tab: the first in front, the rest behind it.
    func open(_ links: [BookmarkNode], profile: String, fromTab key: String? = nil) {
        for (index, node) in links.enumerated() {
            open(node, profile: profile, disposition: index == 0 ? .newTab : .backgroundTab, fromTab: key)
        }
    }
}

extension AppServices {
    /// The pane controller that shows tab `key`, in any window.
    func paneShowing(tab key: String) -> PaneController? {
        guard let (_, pane) = locateTabOnAnyMachine(key) else { return nil }
        return paneController(for: pane)
    }
}
