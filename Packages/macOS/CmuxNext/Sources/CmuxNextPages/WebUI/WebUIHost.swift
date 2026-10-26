public import CmuxNextCompat
public import CmuxNextDesign
import AppKit
public import WebKit

/// The app's one owner of cmux pages (plans/cmux-next/chrome-parity/p13-webui.md 3.A): it makes
/// every page view (``open(_:)``), ends it (``close(_:)``), and knows every page it opened.
///
/// Chrome keeps WebUI behind one owner per profile in the same way: `WebUIControllerFactory`
/// makes each WebUI and `WebUIContentsPreloadManager` holds the single preload
/// (chrome/browser/ui/webui/top_chrome/webui_contents_preload_manager.h), so no page reaches the
/// engine around it. The composition root (`AppServices.webUI`) builds exactly one; a test builds
/// its own with a fake Chromium host. Nothing here is static: the app's host lists its views in
/// ``PageRegistry/processWide`` only while the static forwarders (`PageWebView.chromiumHosting`,
/// `PageWebView.openPanel`, the `PageRegistry` statics) still serve views made outside it
/// (p13-webui-010 removes them).
@MainActor
public final class WebUIHost {
    /// Makes Chromium pages; nil keeps every page on WebKit (a build or test without Chromium).
    public let chromium: (any PageChromiumHosting)?
    /// Answers a WebKit page's `<input type="file">`; nil: a file input does nothing.
    public let openPanel: MadeAheadOpenPanel?
    /// The app's one memory pressure service, for the page lifecycle and the preload slot that
    /// subscribe through this host (p13-webui-043, 047).
    public let memoryPressure: MemoryPressureEvents
    /// The live page views, for the debug verbs and the key dispatcher.
    public let registry: PageRegistry
    /// The shared web content processes of the WebKit pages that ask for them
    /// (``PageEngineOptions/sharesWebKitProcess``, the agent pages).
    public let processGroups: WebProcessGroups
    /// Every page's Active, Hidden, Frozen and Discarded states (p13-webui.md 3.C), fed by the tab
    /// content lifecycle; a page it holds leaves it on ``close(_:)``. Nil while `pageLifecycle` is off:
    /// the composition root sets it.
    package var lifecycle: PageLifecycle?
    /// The clock of each opened page's Chromium deadline (tests pass one that never fires).
    private let clock: any Clock<Duration>
    /// Every page this host opened and has not closed. Weak, so a view a provider drops without
    /// closing it still deinits (p13-webui-061 makes every tab close call ``close(_:)``).
    private let opened = NSHashTable<PageWebView>.weakObjects()

    /// - Parameters:
    ///   - chromium: The app's Chromium page maker (`ChromiumPageHost`); nil for WebKit only.
    ///   - openPanel: The app's made-ahead open panel (`AppServices.openPanel`).
    ///   - memoryPressure: The app's one memory pressure service.
    ///   - registry: Where opened views are listed (the app passes ``PageRegistry/processWide``
    ///     until p13-webui-010; a test leaves the default, its own registry).
    ///   - clock: The Chromium deadline's clock.
    ///   - processGroups: The shared WebKit processes (a test passes its own to read the groups).
    public init(chromium: (any PageChromiumHosting)?, openPanel: MadeAheadOpenPanel?,
                memoryPressure: MemoryPressureEvents, registry: PageRegistry = PageRegistry(),
                clock: any Clock<Duration> = ContinuousClock(), processGroups: WebProcessGroups = WebProcessGroups()) {
        self.chromium = chromium
        self.openPanel = openPanel
        self.memoryPressure = memoryPressure
        self.registry = registry
        self.clock = clock
        self.processGroups = processGroups
    }

    /// Makes and starts loading the page `request` asks for, in the engine ``PageEnginePolicy``
    /// picks with this host's Chromium.
    ///
    /// - Parameter request: The page, its root, routes and options.
    /// - Returns: The view, or nil when the page has no root it may be served from (missing from
    ///   the bundle, or a first-party page asked for at another root).
    public func open(_ request: PageOpenRequest) -> PageWebView? {
        guard let view = PageWebView(request: request, chromium: chromium, openPanel: openPanel,
                                     registry: registry, processGroups: processGroups) else { return nil }
        // Read when the Chromium page reaches the host, after this turn; set before then.
        view.chromiumClock = clock
        opened.add(view)
        return view
    }

    /// Ends `view`: its routes, bridge and engine page, and drops it from the host's lists. Safe to
    /// call twice and for a view this host did not open (it is only closed).
    ///
    /// - Parameter view: The page to end.
    public func close(_ view: PageWebView) {
        view.close()
        opened.remove(view)
        registry.remove(view)
        lifecycle?.forget(view)
    }

    /// A configuration in the process pool and data store of the grouped WebKit pages
    /// (``processGroups``), for a page-less WebKit warm-up view: WebKit's first-use setup and the
    /// pool's one-time font listing (R81) then run before the first grouped page opens, and that
    /// page can use the warm-up's web content process.
    public func groupedWebKitConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = PageProcessPool.forNewView
        configuration.websiteDataStore = processGroups.dataStore
        return configuration
    }

    /// The pages this host opened and has not closed, oldest first.
    public var openPages: [PageWebView] {
        opened.allObjects.sorted { registry.instance(of: $0) < registry.instance(of: $1) }
    }
}
