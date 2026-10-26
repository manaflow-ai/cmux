public import WebKit

/// Puts the page host's WebKit pages that ask for it (``PageEngineOptions/sharesWebKitProcess``:
/// the agent pages, the New Tab page and chats) into shared web content processes, at most
/// ``pagesPerProcess`` pages per process (plans/cmux-next/sequoia-lag.md). ``WebUIHost`` owns one.
///
/// WebKit starts a web content process for every web view, also when the views share one
/// `WKProcessPool`. Every Cmd-T, Cmd-D and Cmd-N opens a New Tab page, so spamming them started a
/// process per tab: in the Tart stress 55 tabs ran 54 WebContent processes (3.8 to 4.5 GB, about
/// one core of CPU) on macOS 14, 15 and 26, each also compiling the 4 MB pane bundle again. A web
/// view made with an earlier page as its related web view (`_relatedWebView`, the WebKit SPI
/// Safari uses for `window.open`) runs in that page's process, and WebKit shares a process only
/// between views of one data store, so the grouped pages use ``dataStore``. The group size bounds
/// what one crash takes down (each page reloads itself) and how many pages share one process's
/// main thread. Chromium groups its renderers per site the same way
/// (content/browser/site_instance_impl.cc, `RenderProcessHostImpl::GetProcessHostForSiteInstance`).
///
/// ```swift
/// let webView = groups.webView(for: configuration) { WKWebView(frame: .zero, configuration: $0) }
/// ```
@MainActor
public final class WebProcessGroups {
    /// The most pages one web content process serves.
    public let pagesPerProcess: Int
    /// The in-memory data store every grouped page uses, and the WebKit warm-up view
    /// (``WebUIHost/groupedWebKitConfiguration()``), so its process can serve the first page. The
    /// grouped pages also share their localStorage (the New Tab page's chat list and folders).
    public let dataStore: WKWebsiteDataStore
    /// The first page of the current group; its process serves the next pages.
    private weak var anchor: WKWebView?
    /// Pages made in the current group, the anchor included.
    private var members = 0

    /// - Parameters:
    ///   - pagesPerProcess: The most pages one process serves (at least 1; `SubsystemBudget.webProcessPagesPerGroup`).
    ///   - dataStore: The grouped pages' data store.
    public init(pagesPerProcess: Int = 8, dataStore: WKWebsiteDataStore = .nonPersistent()) {
        self.pagesPerProcess = max(pagesPerProcess, 1)
        self.dataStore = dataStore
    }

    /// Makes the page's web view with `make` from `configuration`, related to the current group's
    /// first page while that page lives, the group has room and both use the same process pool and
    /// data store (WebKit shares a process only then). Otherwise the view starts a new group.
    public func webView<View: WKWebView>(for configuration: WKWebViewConfiguration,
                                         make: (WKWebViewConfiguration) -> View) -> View {
        if let anchor, members < pagesPerProcess,
           anchor.configuration.processPool === configuration.processPool,
           anchor.configuration.websiteDataStore === configuration.websiteDataStore,
           Self.relate(configuration, to: anchor) {
            members += 1
            return make(configuration)
        }
        let view = make(configuration)
        anchor = view
        members = 1
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
