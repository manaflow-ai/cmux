/// The host's favicon source for the native New Tab page. Both closures run only in the view's background
/// observation task, never while the field ranks a keystroke, so a missing icon arrives later and the row keeps
/// its fixed icon box meanwhile.
public struct NativeNewTabFavicons {
    /// A number that changes when the host's favicon store or bookmarks change.
    public var revision: @MainActor () -> Int
    /// Rebuilds the page's favicon-bearing lists: the host reads its caches, never the network.
    public var page: @MainActor (AgentPaneNewTab) -> AgentPaneNewTab

    public init(revision: @escaping @MainActor () -> Int, page: @escaping @MainActor (AgentPaneNewTab) -> AgentPaneNewTab) {
        self.revision = revision
        self.page = page
    }
}

extension AgentPaneNewTab {
    /// This page with the favicon-bearing lists (open tabs, history, bookmarks) taken from `fresh`; the rest stays.
    public func refreshingSuggestions(_ fresh: AgentPaneOmnibar) -> AgentPaneNewTab {
        var refreshed = self
        refreshed.omnibar.tabs = fresh.tabs
        refreshed.omnibar.history = fresh.history
        refreshed.omnibar.bookmarks = fresh.bookmarks
        return refreshed
    }
}
