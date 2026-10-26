public import WebKit

/// The WebKit side of the page process groups (plans/cmux-next/chrome-parity/p13-webui.md 3.B): one
/// process pool for every page and agent view, one non-persistent data store per
/// ``PageProcessGroup`` that shares stores (``sharedStoreGroups``; a page of another group gets a store
/// of its own, freed with it), and web content processes shared within a related group, at most
/// ``pagesPerProcess`` pages per process. ``WebUIHost`` owns the app's one instance.
///
/// WebKit starts a web content process for every web view, also when the views share one
/// `WKProcessPool`. A web view made with an earlier page as its related web view (`_relatedWebView`,
/// the WebKit SPI Safari uses for `window.open`) runs in that page's process; WebKit relates two
/// views only when they share the pool and the data store, so each group has its own store. This is
/// Chrome's process-per-site rule for WebUI with a cap
/// (content/browser/renderer_host/render_process_host_impl.cc, `GetProcessHostForSiteInstance` with
/// `ShouldUseProcessPerSite`; the cap is `kProcessPerSiteUpToMainFrameThreshold`). The cap bounds
/// what one crash takes down and how many pages share one process's main thread: in the Tart stress
/// 55 New Tab pages without groups ran 54 WebContent processes (3.8 to 4.5 GB, plans/cmux-next/sequoia-lag.md).
///
/// `solo` and `secrets` pages are never related to another view (``PageProcessGroup/sharesRenderer``),
/// whatever ``init(processPool:pagesPerProcess:relatedGroups:sharedStoreGroups:makeStore:)`` is given.
///
/// ```swift
/// groups.configure(configuration, for: .agent)
/// let view = groups.webView(for: .agent, configuration: configuration, joins: true, make: makePageView)
/// ```
@MainActor
public final class PageProcessGroups {
    /// The pool every page and agent view is made in (fonts are registered once per pool, about
    /// 25 ms of a 30 ms page build, R81 trace).
    public let processPool: WKProcessPool
    /// The most pages one web content process serves.
    public let pagesPerProcess: Int
    /// The groups whose views share processes; never `solo` or `secrets`.
    public let relatedGroups: Set<PageProcessGroup>
    /// The groups whose pages share one data store for the app's life (every related group too:
    /// WebKit relates views only in one store). Pages of other groups get a new store each.
    public let sharedStoreGroups: Set<PageProcessGroup>
    private let makeStore: @MainActor () -> WKWebsiteDataStore
    private var stores: [PageProcessGroup: WKWebsiteDataStore] = [:]
    private var anchors: [PageProcessGroup: Anchor] = [:]

    /// The first view of a group's current process and how many views were made in it.
    private struct Anchor {
        weak var view: WKWebView?
        var members: Int
    }

    /// - Parameters:
    ///   - processPool: The pool of every view made here.
    ///   - pagesPerProcess: The most pages one process serves (at least 1).
    ///   - relatedGroups: The groups whose views share processes; groups that do not share a
    ///     renderer are dropped.
    ///   - sharedStoreGroups: The groups whose pages share one data store; the related groups are added.
    ///   - makeStore: Makes a data store: once per shared group on its first use, else once per page.
    public init(processPool: WKProcessPool, pagesPerProcess: Int = 8, relatedGroups: Set<PageProcessGroup>,
                sharedStoreGroups: Set<PageProcessGroup>, makeStore: @escaping @MainActor () -> WKWebsiteDataStore) {
        self.processPool = processPool
        self.pagesPerProcess = max(pagesPerProcess, 1)
        let related = relatedGroups.filter(\.sharesRenderer)
        self.relatedGroups = related
        self.sharedStoreGroups = sharedStoreGroups.union(related)
        self.makeStore = makeStore
    }

    /// The data store of a new `group` page: the group's one store (made on its first use) when the
    /// group shares stores, else a new store for that page alone.
    public func dataStore(for group: PageProcessGroup) -> WKWebsiteDataStore {
        guard sharedStoreGroups.contains(group) else { return makeStore() }
        if let store = stores[group] { return store }
        let store = makeStore()
        stores[group] = store
        return store
    }

    /// Whether a WebKit view made for a `madeFor` page may show a `group` page (a pooled spare
    /// claimed for another page): its data store must be the one a new `group` page gets, so either
    /// the groups match or neither shares a store (each page has its own).
    public func mayShow(_ group: PageProcessGroup, inViewMadeFor madeFor: PageProcessGroup) -> Bool {
        group == madeFor || (!sharedStoreGroups.contains(group) && !sharedStoreGroups.contains(madeFor))
    }

    /// Sets `configuration`'s process pool and `group`'s data store.
    public func configure(_ configuration: WKWebViewConfiguration, for group: PageProcessGroup) {
        configuration.processPool = processPool
        configuration.websiteDataStore = dataStore(for: group)
    }

    /// Makes a `group` page's web view with `make` from `configuration` (set up by
    /// ``configure(_:for:)``). In a related group it is related to the group's current anchor while
    /// that view lives, has room and uses the same pool and store; otherwise it becomes the anchor.
    /// A view of a group that is not related, or that does not `join`, is made as it is.
    ///
    /// - Parameter joins: False for a view that never loads (a Chromium page's WebKit view): relating
    ///   it would start its anchor's process, and as the anchor it would hold no process for the next pages.
    public func webView<View: WKWebView>(for group: PageProcessGroup, configuration: WKWebViewConfiguration,
                                         joins: Bool, make: (WKWebViewConfiguration) -> View) -> View {
        guard joins, relatedGroups.contains(group) else { return make(configuration) }
        if var anchor = anchors[group], let view = anchor.view, anchor.members < pagesPerProcess,
           view.configuration.processPool === configuration.processPool,
           view.configuration.websiteDataStore === configuration.websiteDataStore,
           Self.relate(configuration, to: view) {
            anchor.members += 1
            anchors[group] = anchor
            return make(configuration)
        }
        let view = make(configuration)
        anchors[group] = Anchor(view: view, members: 1)
        return view
    }

    /// Sets `_relatedWebView`; false when this WebKit has no such SPI (the page gets its own process).
    private static func relate(_ configuration: WKWebViewConfiguration, to view: WKWebView) -> Bool {
        // crash-allow: WebKit private selector, used only after responds(to:) confirms it exists (no unknown-selector exception).
        let selector = NSSelectorFromString("_setRelatedWebView:")
        guard configuration.responds(to: selector) else { return false }
        // crash-allow: WebKit private selector, used only after responds(to:) confirms it exists (no unknown-selector exception).
        configuration.perform(selector, with: view)
        return true
    }
}
