import Foundation

/// The open browser tabs of one store by site (a key the owner computes from each tab's address: the App's
/// `BookmarkURL.faviconKey`, `https://host[:port]`), for the icon a row of that site draws: each omnibar suggestion
/// row, bookmark, New Tab page item and sidebar link asks with its site and reads the tabs of that site alone
/// (`AppServices.siteFaviconAddress`, `openTabFaviconsByOrigin`).
///
/// Kept by the store's browser changes (``StoreTabRoles/followBrowsers(_:_:)``, once per publish, only the records a
/// change names), never by a walk of the tree: a navigation re-files its own tab, and a terminal's change costs
/// nothing (hot-path audit 3, H5). Readers observe the store's browser revision, not every pane's tab list. The
/// store's follow holds it weakly; its owner keeps it.
@MainActor
public final class BrowserTabsBySite {
    private let store: DaemonStore
    private let site: (String) -> String?
    /// Each indexed tab's site, and the tabs of each site.
    private var sites: [ObjectIdentifier: String] = [:]
    private var tabsBySite: [String: [ObjectIdentifier: TabModel]] = [:]

    /// - Parameters:
    ///   - store: The store whose open browser tabs it files.
    ///   - site: A tab address's site key; nil files the tab under none.
    public init(store: DaemonStore, site: @escaping (String) -> String?) {
        self.store = store
        self.site = site
        for tab in store.tabRoles.browserTabs { file(ObjectIdentifier(tab), tab) }
        store.tabRoles.followBrowsers(self) { [weak self] changes in
            guard let self else { return }
            for change in changes { file(change.record, change.tab) }
        }
    }

    /// The open browser tabs on `site`, by tab id. Observes the store's browser revision.
    // perf-hot: 5us omnibar-key (every suggestion row's icon, and each bookmark, New Tab item and link)
    public func tabs(at site: String) -> [TabModel] {
        _ = store.tabRoles.browserRevision
        guard let tabs = tabsBySite[site] else { return [] }
        return tabs.count == 1 ? Array(tabs.values) : tabs.values.sorted { $0.id < $1.id }
    }

    /// Every site with an open browser tab, and its tabs by tab id. Observes the store's browser revision.
    public func bySite() -> [(site: String, tabs: [TabModel])] {
        _ = store.tabRoles.browserRevision
        return tabsBySite.map { ($0.key, $0.value.values.sorted { $0.id < $1.id }) }
    }

    /// Files `record` under its tab's site now (none: `tab` is nil, no longer a browser tab of the store).
    private func file(_ record: ObjectIdentifier, _ tab: TabModel?) {
        let key = tab?.url.flatMap(site)
        if let old = sites[record], old != key || tab == nil {
            tabsBySite[old]?[record] = nil
            if tabsBySite[old]?.isEmpty == true { tabsBySite[old] = nil }
        }
        sites[record] = tab == nil ? nil : key
        if let key, let tab { tabsBySite[key, default: [:]][record] = tab }
    }
}
