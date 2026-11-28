import CmuxNextAgentActivity
import CmuxNextBookmarks
import CmuxNextDesign
import CmuxNextHistory
import CmuxNextIcons
import CmuxNextRemoteView
import CmuxNextTabs
import Foundation

/// What a browser tab shows where its icon goes (Chromium's `TabIcon`
/// rule): a cmux page's own icon, the throbber while the page loads, else
/// the page's favicon, else the browser icon (no favicon yet, none, or its
/// fetch failed). Pure.
enum BrowserTabIconState: Equatable {
    case throbber
    case favicon(TabImage)
    case globe
    /// A cmux page (`cmux://history`, ...) shown in the browser tab.
    case page(IconName)

    /// `isLoading` is the live page's load state; a hibernated tab has no
    /// live page, so it shows its favicon and never the throbber. `url` is
    /// the tab's address: a cmux page's address wears that page's icon.
    /// `showsLoading` off (`appearance.statusIndicator.showPageLoading`, the
    /// default reads the live setting) keeps the favicon while the page loads.
    static func resolve(isLoading: Bool, isDormant: Bool, favicon: TabImage?, url: URL? = nil,
                        showsLoading: Bool = DesignSettings.shared.statusIndicator.showsPageLoading) -> BrowserTabIconState {
        if let page = pageIcon(url) { return .page(page) }
        if isLoading, !isDormant, showsLoading { return .throbber }
        return favicon.map(BrowserTabIconState.favicon) ?? .globe
    }

    /// The icon of the cmux page at `url`, nil for any other address.
    static func pageIcon(_ url: URL?) -> IconName? {
        if HistoryPageAddress.matches(url) { return .history }
        if BookmarkPageAddress.matches(url) { return .bookmarkManager }
        if AgentActivityPageAddress.matches(url) { return .agentActivity }
        if url?.scheme?.lowercased() == RemoteViewTabRecord.scheme, url?.host()?.lowercased() == RemoteViewTabRecord.urlHost { return .machineRemote }
        if TabContentCache.isRemoteBrowserPage(url) { return .machineRemote }
        return nil
    }

    /// Applies this state to a strip item (the throbber is the strip's busy
    /// spinner in place of the icon; the browser icon is the item's default).
    func apply(to item: inout TabItem) {
        switch self {
        case .throbber: item.isBusy = true
        case .favicon(let image): item.icon = .image(image)
        case .globe: item.icon = .icon(.browser)
        case .page(let name): item.icon = .icon(name)
        }
    }
}
