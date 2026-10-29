public import WebKit

/// Puts the page host's WebKit pages into shared web content processes, at most ``pagesPerProcess``
/// pages per process (plans/cmux-next/sequoia-lag.md, plans/cmux-next/chrome-parity/p07-memory.md 087).
/// ``WebUIHost`` owns one; the composition root sizes it from `SubsystemBudget.webProcessPagesPerGroup`.
///
/// WebKit starts a web content process for every web view, also when the views share one
/// `WKProcessPool`. Every Cmd-T, Cmd-D and Cmd-N opens a New Tab page, so spamming them started a
/// process per tab: in the Tart stress 55 tabs ran 54 WebContent processes (3.8 to 4.5 GB, about
/// one core of CPU) on macOS 14, 15 and 26, each also compiling the 4 MB pane bundle again. A web
/// view made with an earlier page as its related web view (`_relatedWebView`, the WebKit SPI
/// Safari uses for `window.open`) runs in that page's process, and WebKit shares a process only
/// between views of one data store, so each group's pages use that group's store
/// (``dataStore(for:)``): one non-persistent store per group, as Chrome keeps WebUI storage per
/// site, so pages of different groups never share localStorage.
///
/// This is the WebKit side of Chrome's process-per-site for WebUI: Chrome lets WebUI pages share a
/// renderer only within their process lock (content/browser/site_info.cc,
/// `IsWebUIAndUsesTLDForProcessLockURL`) and reuses a site's process through
/// `RenderProcessHostImpl::GetProcessHostForSiteInstance`
/// (content/browser/renderer_host/render_process_host_impl.cc). A cmux page joins the group of its
/// ``PageProcessGroup`` (the capability class ``PageProcessGroupAudit`` checks), so pages share a
/// process only with pages Chromium would let share a renderer: ``Membership`` names the group.
/// There is one group per membership, process pool and data store; a page of another store or pool
/// starts its own group and leaves the others as they are. The group size bounds what one crash
/// takes down (each page of the group hears it and reloads or waits for its show,
/// ``PageCrashRecovery``) and how many pages share one process's main thread.
///
/// ```swift
/// if let membership = groups.membership(of: descriptor, options: options) {
///     let webView = groups.webView(for: configuration, as: membership) { WKWebView(frame: .zero, configuration: $0) }
/// }
/// ```
@MainActor
public final class WebProcessGroups {
    /// Which pages a page may share a web content process with.
    public nonisolated enum Membership: Hashable, Sendable {
        /// The pages of one sharing ``PageProcessGroup`` (``PageProcessGroup/sharesRenderer``).
        case group(PageProcessGroup)
        /// The instances of one page (its descriptor id) that asked to share
        /// (``PageEngineOptions/sharesWebKitProcess``) although its group keeps a renderer each.
        case page(String)
    }

    /// The most pages one web content process serves.
    public let pagesPerProcess: Int
    /// Every page of a sharing ``PageProcessGroup`` joins its group (feature
    /// `webKitPageProcessGroups`); false: only the pages that ask (``PageEngineOptions/sharesWebKitProcess``).
    public let groupsEverySharingPage: Bool
    /// Makes a group's in-memory data store at the group's first page (``dataStore(for:)``).
    private let makeStore: @MainActor () -> WKWebsiteDataStore
    /// The data store of each membership, for the app's life.
    private var stores: [Membership: WKWebsiteDataStore] = [:]
    /// The current group of each membership, process pool and data store.
    private var groups: [Key: Group] = [:]

    /// A group's identity: WebKit shares a process only between views of one pool and one store.
    private nonisolated struct Key: Hashable {
        let membership: Membership
        let pool: ObjectIdentifier
        let store: ObjectIdentifier
    }

    /// The first page of a group, whose process serves the next pages, and how many pages it made.
    private struct Group {
        weak var anchor: WKWebView?
        var members: Int
    }

    /// - Parameters:
    ///   - pagesPerProcess: The most pages one process serves (at least 1; `SubsystemBudget.webProcessPagesPerGroup`).
    ///   - groupsEverySharingPage: Every page of a sharing group joins it (``groupsEverySharingPage``).
    ///   - makeStore: Makes a group's data store, once per membership at its first use.
    public init(pagesPerProcess: Int, groupsEverySharingPage: Bool = false,
                makeStore: @escaping @MainActor () -> WKWebsiteDataStore = { .nonPersistent() }) {
        self.pagesPerProcess = max(pagesPerProcess, 1)
        self.groupsEverySharingPage = groupsEverySharingPage
        self.makeStore = makeStore
    }

    /// The in-memory data store of `membership`'s pages: made at its first use and kept for the
    /// app's life, so the group's pages share their localStorage per origin (the agent group's New Tab
    /// page and chats share the chat list and folders) and another group's pages never see it. The
    /// WebKit warm-up view takes the agent group's (``WebUIHost/groupedWebKitConfiguration()``).
    public func dataStore(for membership: Membership) -> WKWebsiteDataStore {
        if let store = stores[membership] { return store }
        let store = makeStore()
        stores[membership] = store
        return store
    }

    /// The group `descriptor`'s page joins when it shows in WebKit, nil when it keeps a process of
    /// its own: a `secrets` page always does, a `solo` page unless it asks to share, and a page of a
    /// sharing group only when it asks or ``groupsEverySharingPage`` is on.
    public func membership(of descriptor: PageDescriptor, options: PageEngineOptions) -> Membership? {
        let group = descriptor.processGroup
        if group.sharesRenderer, options.sharesWebKitProcess || groupsEverySharingPage { return .group(group) }
        if options.sharesWebKitProcess, group != .secrets { return .page(descriptor.id) }
        return nil
    }

    /// Makes the page's web view with `make` from `configuration`, related to the first page of its
    /// group (`membership` in `configuration`'s pool and store) while that page lives and the group
    /// has room. Otherwise the view starts a new group of that key.
    public func webView<View: WKWebView>(for configuration: WKWebViewConfiguration, as membership: Membership,
                                         make: (WKWebViewConfiguration) -> View) -> View {
        let key = Key(membership: membership, pool: ObjectIdentifier(configuration.processPool),
                      store: ObjectIdentifier(configuration.websiteDataStore))
        // Groups whose first page closed start again at their next page; O(live groups), a handful.
        groups = groups.filter { $0.value.anchor != nil }
        if let group = groups[key], let anchor = group.anchor, group.members < pagesPerProcess,
           anchor.configuration.processPool === configuration.processPool,
           anchor.configuration.websiteDataStore === configuration.websiteDataStore,
           Self.relate(configuration, to: anchor) {
            groups[key]?.members += 1
            return make(configuration)
        }
        let view = make(configuration)
        groups[key] = Group(anchor: view, members: 1)
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
