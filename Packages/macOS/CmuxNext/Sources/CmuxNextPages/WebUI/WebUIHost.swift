public import CmuxNextCompat
public import CmuxNextDesign
import AppKit
package import CmuxNextSignposts
public import CmuxNextWakeups
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
    /// The live page views, for the debug verbs and the key dispatcher.
    public let registry: PageRegistry
    /// The shared web content processes of the WebKit pages (``WebProcessGroups/membership(of:options:)``:
    /// the agent pages, and with `webKitPageProcessGroups` every page of a sharing group). Nil: every
    /// WebKit page starts a process of its own, as before the groups (a test host that reads no groups).
    public let processGroups: WebProcessGroups?
    /// The daemon relay channels of the pages (one per daemon page id), kept here instead of a
    /// static: each closes its daemon connection when idle.
    public let relayChannels = PageRelayChannels()
    /// Every page's Active, Hidden, Frozen and Discarded states (p13-webui.md 3.C), fed by the tab
    /// content lifecycle; a page it holds leaves it on ``close(_:)``. Nil while `pageLifecycle` is off:
    /// the composition root sets it.
    package var lifecycle: PageLifecycle?
    /// The frame every page this host opens delivers its router envelopes on, one script per page
    /// per frame (``PageWebView/deliverOnFrames(_:)``). Nil while
    /// `pageScriptFrames` is off: each envelope is its own script, as before. The composition root sets it.
    package var scriptFrames: PageScriptFrame?
    /// Where the WebKit content-process ends of the pages this host opens go as stability events.
    /// Nil records none; the composition root sets the app's one.
    package var rendererStability: RendererStability?
    /// The app's one preloaded page (p13-webui.md 3.D); the host's memory registration
    /// (`preloadMemory`) drops it at any level but normal. Nil until the composition root installs it
    /// with the app's deadline scheduler; installing it hands it the current level.
    package var preload: PagePreloadSlot? {
        didSet { preloadLevelDidChange() }
    }
    /// The preload slot's place in the app's one memory pressure path: a spare
    /// consumer of the memory coordinator, as Chromium's spare windows are (`ChromiumWarmup`). The
    /// coordinator hands every spare the level in the level's own turn, the debug override included,
    /// and runs the critical urgent discard pass over tabs, chats and pages (`BrowserHibernation`) on a
    /// later frame, so the cheapest memory, nothing a person made, goes first.
    private var preloadMemory: SpareMemoryConsumer?
    /// The crash budgets of the pages that share a renderer (p13-webui.md 3.C). A page opened while
    /// ``lifecycle`` is set uses them and loads after a crash it had while hidden when it shows
    /// (``PageCrashRecovery``); without the lifecycle each page keeps its own and reloads at once. The
    /// composition root sets them with the lifecycle: Chromium's grouping and how to read a renderer.
    package var crashGroups = PageCrashGroups()
    /// The windows' frame-aligned pointer input (feature `pointerFrameHover`, the App's
    /// `hoverFrameInput`): each page this host opens gets it for its popup's rows
    /// (``PageWebView/popupHoverFrameInput``). Nil: each move hovers at once.
    public let hoverFrameInput: FrameInputCoalescers?
    /// The app's one deadline scheduler: each opened page's deadlines (its claim and Chromium fallbacks) and its
    /// settings pushes run on it (``PageWebView/deadlines``). A test passes one whose wakes it fires by hand.
    public let deadlines: MainDeadlineScheduler
    /// A page starts its document, and its renderer, at its first show, not when it opens
    /// (feature `pageRendererAtFirstShow`, PageWebView+FirstShow.swift).
    public let startsPagesAtFirstShow: Bool
    /// Ends closed pages after the close's turn (``close(_:)``); the agent tabs retire
    /// their panes on it too, so the app has one teardown deadline.
    public let retirer: PageRetirer
    /// Every page this host opened and has not closed. Weak, so a view a provider drops without
    /// closing it still deinits (p13-webui-061 makes every tab close call ``close(_:)``).
    private let opened = NSHashTable<PageWebView>.weakObjects()
    /// Follows `web-dev.json` (``WebDevOverride``): a change reaches the pages as a web update does
    /// (``webBundleDidChange()``). Armed by the first page ``open(_:)`` makes, a preloaded one included
    /// (``PagePreloads`` opens through it), so a launch that shows no page reads nothing; the first page
    /// loads bundled and reloads once the file is read.
    public let devOverride = WebDevOverrideWatcher()
    /// A web files change reloads only the shown pages; hidden and frozen ones reload after they show,
    /// once they allow it (feature `webUpdateReloadOnShow`, ``webBundleDidChange()``, ``bundleSafePoint``).
    /// Off: every page reloads at the change.
    package var bundleReloadsOnShow = false
    /// Takes each page this host opens when it shows with web files it has not loaded (the app's web
    /// updates): it asks the page before it reloads it (``WebBundleSafePoint``). Set before the first open.
    package weak var bundleSafePoint: (any WebBundleSafePoint)?
    #if DEBUG || CMUX_BENCH_HOOKS
    /// Yields when a page's oracle reading may have changed (the `webviews` facet's wait): a page
    /// ``observeOracleState(of:)`` hooked posted ``PageRouter/oracleStateChangedOp`` or its document loaded.
    public let oracleChanges = PageOracleChangeFeed()
    /// The engine page closes of this host's pages (`debug.webui` `retire`): a close in ``close(_:)``'s turn
    /// is the Cmd-W cost the retirer removes.
    public private(set) var engineCloses = WebUICensus.EngineCloses()
    /// The system uptime each engine close is stamped with (tests pass their own).
    var engineCloseUptime: @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }
    /// ``close(_:)`` runs now (nested closes count each).
    private var closing = 0
    #endif

    /// - Parameters:
    ///   - chromium: The app's Chromium page maker (`ChromiumPageHost`); nil for WebKit only.
    ///   - openPanel: The app's made-ahead open panel (`AppServices.openPanel`).
    ///   - memory: The app's memory coordinator: the preload slot registers with it at once.
    ///   - registry: Where opened views are listed (the app passes ``PageRegistry/processWide``
    ///     until p13-webui-010; a test leaves the default, its own registry).
    ///   - deadlines: The app's deadline scheduler (`AppServices.mainDeadlines`); a test passes its own
    ///     (`.testing()`) or one whose wakes it fires by hand.
    ///   - processGroups: The shared WebKit processes, sized by the composition root
    ///     (`SubsystemBudget.webProcessPagesPerGroup`); nil: none (``processGroups``).
    ///   - startsPagesAtFirstShow: Pages start their document at their first show (``startsPagesAtFirstShow``).
    ///   - hoverFrameInput: The frame-aligned pointer input of the pages' popups; nil: each move.
    ///   - retirer: Ends closed pages after the close's turn; nil: one on `deadlines`.
    public init(chromium: (any PageChromiumHosting)?, openPanel: MadeAheadOpenPanel?,
                memory: any MemoryConsumerRegistry, registry: PageRegistry = PageRegistry(),
                deadlines: MainDeadlineScheduler,
                processGroups: WebProcessGroups? = nil,
                startsPagesAtFirstShow: Bool = false, hoverFrameInput: FrameInputCoalescers? = nil,
                retirer: PageRetirer? = nil) {
        self.chromium = chromium
        self.retirer = retirer ?? PageRetirer(deadlines: deadlines)
        self.startsPagesAtFirstShow = startsPagesAtFirstShow
        self.hoverFrameInput = hoverFrameInput
        self.openPanel = openPanel
        self.registry = registry
        self.deadlines = deadlines
        self.processGroups = processGroups
        devOverride.onChange = { [weak self] in _ = self?.webBundleDidChange() }
        preloadMemory = SpareMemoryConsumer(
            name: "webui-preload", registry: memory, spares: { [weak self] in self?.preload?.count ?? 0 },
            drop: { [weak self] in self?.preloadLevelDidChange() }, refill: { [weak self] in self?.preloadLevelDidChange() })
    }

    /// The memory pressure level the preload slot follows (the coordinator's, the debug override
    /// included); normal until the registration hands the first one.
    private var memoryLevel: MemoryPressureLevel { preloadMemory?.level ?? .normal }

    /// Hands the slot the coordinator's level: anything but normal drops its page and holds new ones.
    private func preloadLevelDidChange() {
        preload?.memoryPressureDidChange(memoryLevel)
    }

    /// Makes the page `request` asks for, in the engine ``PageEnginePolicy`` picks with this host's
    /// Chromium, and starts loading it now, or at its first show with ``startsPagesAtFirstShow``.
    ///
    /// - Parameter request: The page, its root, routes and options.
    /// - Returns: The view, or nil when the page has no root it may be served from (missing from
    ///   the bundle, or a first-party page asked for at another root).
    public func open(_ request: PageOpenRequest) -> PageWebView? {
        devOverride.start() // once; nothing unless the override is available
        guard let view = PageWebView(request: request, chromium: chromium, openPanel: openPanel, registry: registry,
                                     processGroups: processGroups, startsAtFirstShow: startsPagesAtFirstShow,
                                     deadlines: deadlines) else { return nil }
        if lifecycle != nil { view.crash.groups = crashGroups }
        view.crash.stability = rendererStability
        view.popupHoverFrameInput = hoverFrameInput
        view.bundleSafePoint = bundleSafePoint
        if let scriptFrames { view.deliverOnFrames(scriptFrames) }
        opened.add(view)
        #if DEBUG || CMUX_BENCH_HOOKS
        observeOracleState(of: view)
        view.censusState.engineClosed = { [weak self] in self?.noteEngineClose() }
        #endif
        return view
    }

    /// Ends `view`. Now: it leaves the view tree, the host's lists and its own crash budget, and its
    /// routes, subscriptions and bridge end, so nothing serves a page no tab shows. At the
    /// ``retirer``'s deadline: its engine page ends, never in the close's turn (Cmd-W makes no engine
    /// close call). Safe to call twice and for a view this host did not open (it is only ended).
    ///
    /// - Parameter view: The page to end.
    public func close(_ view: PageWebView) {
        #if DEBUG || CMUX_BENCH_HOOKS
        closing += 1
        defer { closing -= 1 }
        #endif
        opened.remove(view)
        registry.remove(view)
        lifecycle?.forget(view)
        crashGroups.forget(ObjectIdentifier(view))
        view.closeRoutes()
        retirer.retire(view) { view.closeEngine() }
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    private func noteEngineClose() {
        engineCloses.record(at: engineCloseUptime(), inCloseTurn: closing > 0)
    }
    #endif

    /// A configuration in the process pool and the agent group's data store (``processGroups``,
    /// ``WebProcessGroups/dataStore(for:)``), for a page-less WebKit warm-up view: WebKit's first-use
    /// setup and the pool's one-time font listing (R81) then run before the first agent page opens,
    /// and that page can use the warm-up's web content process. Without groups the store is the warm-up's own.
    public func groupedWebKitConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = PageProcessPool.forNewView
        configuration.websiteDataStore = processGroups?.dataStore(for: .group(.agent)) ?? .nonPersistent()
        return configuration
    }

    /// The pages this host opened and has not closed, oldest first.
    public var openPages: [PageWebView] {
        opened.allObjects.sorted { registry.instance(of: $0) < registry.instance(of: $1) }
    }
}

// The served web files change (a web UI update at its safe point, a `web-dev.json` change): only the
// pages a person sees are asked and reloaded (p13-webui.md 3.C, task 071).
extension WebUIHost: WebBundleHost {
    /// Every live WebKit page of the host's registry (``PageWebView/bundleServedByOverlay``), which
    /// lists the pages it opened and, in the app, the views made outside it while the static
    /// forwarders remain, the preload slot's parked page included. With
    /// ``bundleReloadsOnShow``, not the preloaded page, which nobody sees and the swap makes again.
    package var webBundlePages: [any WebBundlePage] {
        let preloaded = bundleReloadsOnShow ? preload?.page?.preloadView : nil
        return registry.pages().filter { page in
            page.bundleServedByOverlay && (preloaded.map { !page.isDescendant(of: $0) } ?? true)
        }
    }

    /// With ``bundleReloadsOnShow``, shown pages reload now; hidden and frozen ones are marked and
    /// reload after they show, once they allow it (``PageWebView/bundleStale``, ``bundleSafePoint``),
    /// so a frozen page is never woken, and the
    /// preloaded page is dropped and made again from the new files. Without it, every page that
    /// holds a document reloads now, and the parked page is marked: its claim loads the
    /// new files. A document kept meanwhile keeps loading its lazy chunks from the files it started
    /// with (``WebBundleOverlay/Pin``).
    @discardableResult
    package func webBundleDidChange() -> Int {
        if bundleReloadsOnShow { preload?.dropStale() }
        return reloadOrMarkStale(webBundlePages)
    }
}
