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

    func open(_ url: URL, profile: String, disposition: BookmarkOpenDisposition, fromTab key: String? = nil) {
        let pane = key.flatMap { services.paneShowing(tab: $0) } ?? services.windows.active?.focusedPane
        guard let pane else { return services.registry.refuse(RefusalStrings.noWindowOpen) }
        if disposition == .currentTab, let tab = key.flatMap({ services.cache.tabModel($0) }) ?? pane.selectedTab, tab.kind == .browser,
           let entry = services.cache.existingBrowser(tab.id) {
            if entry.chrome.loadOverride?(url) == true { return }
            entry.tab.load(url)
            return
        }
        pane.newBrowserTab(url: url, background: disposition == .backgroundTab, profile: profile)
    }

    /// Every bookmark directly in `folder`, each in a new tab (Open All).
    func openAll(in folder: String, profile: String, fromTab key: String? = nil) {
        let nodes = services.bookmarks.tree(profile).children(of: folder).filter { !$0.isFolder }
        for (index, node) in nodes.enumerated() {
            open(node, profile: profile, disposition: index == 0 ? .newTab : .backgroundTab, fromTab: key)
        }
    }
}

extension AppServices {
    /// The pane controller that shows tab `key`, in any window.
    func paneShowing(tab key: String) -> PaneController? {
        guard let (_, pane) = locateTab(key) else { return nil }
        return paneController(for: pane)
    }
}
