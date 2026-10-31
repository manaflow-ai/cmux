import AppKit
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHibernation
import CmuxNextLaunch
import CmuxNextMacScreen
import CmuxNextMemory
import CmuxNextPages
import CmuxNextRemote
import CmuxNextSignposts
import CmuxNextTerminal
import CmuxNextWakeups
import Observation
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// Owns every terminal surface and browser page in the process
/// (architecture.md 4). Surfaces are keyed by tab, not by pane: a tab moved
/// to another pane keeps its surface and the destination pane reparents the
/// view (`SurfaceLedger`). Surfaces exist for tabs presented on screen or in
/// the keep-alive band (off-screen columns within one viewport width, paused)
/// plus an LRU of recently hidden ones (`WarmSetBudget`); older hidden surfaces are destroyed and re-attach
/// from the daemon replay when shown. Previews of destroyed surfaces stay in an image LRU sized by
/// ``ImageCacheShares`` from the Mac's memory.
// memory: fixed an owner, not a cache: its maps hold the live surfaces and pages of open tabs (bounded by the warm set, `ledger`, and hibernation); each picture store is its own memory consumer (`previews`, `internalPagePictures`, `pageThumbnails`: PreviewImageCache; `lastFrames`: TerminalLastFrames)
final class TabContentCache {
    private let daemon: DaemonService
    /// Given to every terminal session this cache makes: the modifier watch (``TerminalModifierWatch``), and the scheduler its host follows its models through.
    let terminalModifiers: TerminalModifierWatch?
    /// Given to every terminal session this cache makes: the windows' frame-aligned pointer input (feature
    /// `terminalPointerFrames`); nil: each pointer event reaches Ghostty at once.
    let terminalPointerFrames: FrameInputCoalescers?
    let mainWork: MainWorkScheduler
    var terminals: [String: TerminalEntry] = [:] { didSet { pageRequests.services?.crashKeys?.noteTerminals(terminals.count) } }
    var browsers: [String: BrowserEntry] = [:] {
        didSet {
            pageRequests.services?.crashKeys?.noteBrowsers(in: browsers.values.lazy.map { $0.tab }); guard browsers.count != oldValue.count else { return }
            pageRequests.media.tabsChanged()
            if browsers.count < oldValue.count { tabRenderers.keep(only: Set(browsers.keys)) }
        }
    }
    /// Each Chromium tab's renderers, for the busy watchdog off the main thread: a tab
    /// publishes itself at mount (`CEFTab.publishRenderers`) and leaves with its entry.
    let tabRenderers = TabRendererDirectory()
    var ledger = SurfaceLedger<String, ObjectIdentifier>(capacity: WarmSetBudget.standard.terminalCapacity)
    var presenters: [ObjectIdentifier: WeakPresenter] = [:]
    /// Windows off screen now (`WindowOcclusionChecker`): the pages they show get a hidden clock.
    var offScreenWindows: Set<ObjectIdentifier> = []
    /// Every tab's content phase and visibility generation (plans/cmux-next/tab-lifecycle.md):
    /// the only source of show and hide for terminal surfaces and pages (`TabContentCache+Lifecycle`).
    var lifecycle = ContentLifecycle<String>()
    /// Shown tabs whose content does not exist yet (a Chromium page being created): their `mount` token, answered at install.
    var pendingMounts: [String: ContentLifecycle<String>.Token] = [:]
    /// How many hidden terminal surfaces stay warm, and the memory consumer that sets it under pressure.
    var warmBudget = WarmSetBudget.standard, warmSetRelease: WarmSetRelease?
    /// Lets paused away terminals' GPU memory go (`terminalGPURelease`, `ghostty_surface_set_gpu_resident`); nil: none.
    let gpuResidency: (any TerminalGPUResidency)?
    /// Every terminal session it makes shows its cursor on the render server (feature `terminalCursorLayer`).
    let terminalExternalCursor: Bool
    /// The warm set's capacity at normal pressure (`SubsystemBudget.warmTerminalSurfaces`: larger with
    /// ``gpuResidency``); `WarmSetRelease` scales it under pressure.
    let normalWarmCapacity: Int
    var onRelease: ((String) -> Void)?
    var hibernation: BrowserHibernation? // hibernates hidden browser pages (time, memory pressure) and restores them
    var pageLifecycle: PageLifecycle? // page tabs' freeze and discard, from each reveal and conceal (pageLifecycle; nil while off)
    let contentOwners = ContentLifecycleOwners<ContentLifecycle<String>.Token>() // page and conversation tabs' lifecycle effects (memoryDiscard*; empty while off)
    let dormantTabs = DormantTabs() // hibernated tabs, observed by the tab strips
    /// The full sizes of its picture stores and of the hibernation's (``ImageCacheShares``).
    let imageCaches: ImageCacheShares
    /// Terminal previews, which a terminal pictures again on its next hover: a rebuildable memory consumer
    /// once registered (`memoryImageCaches`), which gives memory back at warning.
    let previews: PreviewImageCache
    /// Discarded internal pages' last pictures (`InternalPageTabStore.discardedPicture(of:)`), the only copy
    /// (a hidden or discarded page cannot be pictured again): a memory consumer the coordinator limits only
    /// at critical pressure.
    let internalPagePictures: PreviewImageCache
    /// New tabs' `create.tab` intervals waiting for their first frame (p09-observability task 030).
    let createTabs = CreateTabTimings()
    /// Evicted terminals' last frames: shown at once when the terminal is shown again, pictured
    /// on demand for its hover card; volatile, bounded by the warm set (`warmBudgetDidChange`).
    let lastFrames = TerminalLastFrames(capacity: WarmSetBudget.standard.terminalCapacity)
    /// Releases terminals whose daemon tree dropped their tab (a closed workspace).
    let goneTabs: GoneTabWatch
    /// The terminal view whose stream rides the input lane, the last one focused, while `terminalStreamPriority`
    /// is on; nil: every view's stream keeps the priority it opened with.
    let streamFocus: TerminalStreamFocus?
    /// Browser pages' hover card thumbnails (R131), at most `TabPreviewFitting.cachedPixelSize`
    /// each, with the page version each shows (`pageVersion`): a page is captured again only when
    /// its version moved. A hidden page's thumbnail is the only copy (the engine cannot picture a
    /// hidden page), so the coordinator limits it only at critical pressure.
    let pageThumbnails: PreviewImageCache
    var pageThumbnailVersions: [String: Int] = [:]
    var pageCapturesInFlight: Set<String> = []
    /// How long a leave capture may take before its thumbnail is dropped (the capture runs on the
    /// main thread). Tests that do not test this deadline use the shared 30 s test configuration.
    var pageCaptureDeadline: Duration = .seconds(2)
    /// Pages revealed since their last hide: the next hide captures their thumbnail (`TabContentCache+Lifecycle`).
    var shownPages: Set<String> = []
    /// Over the Chromium engine's stores, so both engines share them (``BrowserSharedStores``).
    let webKit: WebKitEngine
    /// The Chromium engine, built on its first read (``ChromiumEngineSlot``; its stores are there before it).
    let chromium: ChromiumEngineSlot
    var cef: CEFEngine { chromium.engine }
    /// Pages visited in the default browser profile, shared by its omnibars for suggestions and
    /// inline autocomplete (in memory, durable via `HistoryService`). Others: `history(for:)`.
    let history = InMemoryBrowserHistory()
    private(set) lazy var suggestionEngine = makeSuggestionEngine(history: history, profile: .default)
    var onSuggestionEngineCreated: ((OmniboxSuggestionEngine, BrowserProfileID) -> Void)? // bookmark feed, settings
    var onRevealTab: ((String) -> Void)? // a Switch to Tab row was chosen
    var omniboxConfiguration = OmniboxConfiguration() // browser.searchEngine, browser.omnibar.*
    /// History and suggestions of each non-default browser profile.
    var profileHistories: [BrowserProfileID: ProfileHistory] = [:]
    /// A profile's omnibar history was created or dropped (`HistoryService`).
    var onProfileHistoryCreated: ((BrowserProfileID, InMemoryBrowserHistory) -> Void)?
    var onProfileHistoryDropped: ((BrowserProfileID) -> Void)?
    /// Incognito pages' history and page installs (`TabContentCache+Incognito`).
    var incognitoMemory = IncognitoPageMemory()
    let pageInstalls = PageInstallCounter()
    /// Tab `key`'s browser profile: an incognito window's, else nil (default).
    var browserProfile: ((String) -> BrowserProfileID?)?
    let browserTabs: BrowserTabService
    /// Page-originated tab requests (new-tab links, popups, window.close).
    let pageRequests = BrowserPageRequests()
    /// Chromium pages being created (ChromiumWarmup waits for none, `onPagesSettled`).
    private(set) var pendingBrowsers: Set<String> = [] {
        didSet { if !oldValue.isEmpty, !hasPendingPages { onPagesSettled?() } }
    }
    /// Terminals made before their daemon knew its tab records, waiting to take their record's font scale
    /// (`applyFontScaleWhenKnown`), by tab; each ends when it applies or its tab is released.
    var fontScaleWaits: [String: ServiceObservation<Bool>] = [:]
    /// Tabs whose page waits for `enginesAwait`, one posted step each.
    private var awaitingRead: Set<String> = [] {
        didSet { if !oldValue.isEmpty, !hasPendingPages { onPagesSettled?() } }
    }
    /// A page is being made or waits for the launch read (ChromiumWarmup waits for none).
    var hasPendingPages: Bool { !pendingBrowsers.isEmpty || !awaitingRead.isEmpty }
    /// No Chromium page is being created any more (ChromiumWarmup's spare window).
    var onPagesSettled: (@MainActor () -> Void)?
    private var framedStandIns: Set<String> = [] // stand-in tabs whose page waited for their first frame
    /// Each tab's visibility node, weakly (`node(for:)`).
    private var tabNodes: [String: WeakTabNode] = [:]
    /// `tabNodes` drops its released nodes when it reaches this many entries.
    private var tabNodesPruneAt = 64
    /// The parent of tab nodes that no pane has selected: hidden, so they are.
    private let unselectedTabs = VisibilityNode(root: "tabs.unselected", own: .hidden)
    /// Runs work after the current pass's frame committed (`AfterFrameCommit`); tests pass their own.
    private let afterFrame: (@escaping @MainActor () -> Void) -> Void
    /// Restored browser tabs start as `DeferredBrowserTab` (nothing loads)
    /// until the user reloads one: set after cmux quit unexpectedly twice in a row (`LaunchRecovery.restartedSafely`).
    var defersRestoredPages = false
    /// Tabs whose deferred page the user started.
    var startedDeferred: Set<String> = []
    /// Tabs whose deferred page waits for the launch order (`deferredPage`), not for the person, with the tab
    /// node that starts it when it shows: held here, as `node(for:)` holds nodes weakly.
    var launchDeferredNodes: [String: VisibilityNode] = [:]
    /// The launch read every browser tab's page waits for before an engine makes it (the browser
    /// profiles); nil: none.
    var enginesAwait: LaunchReadEvent?
    /// The browser pages' pictures from the last quit, drawn over their panes at launch (feature `browserLaunchPictures`; nil while off).
    var launchPictures: BrowserLaunchPictures?
    /// Agent marks of tabs (`TabContentCache+AgentDriven`); kept across hibernation and restarts of the page.
    var agentMarks = TabAgentMarks()
    /// Creates a Chromium page (asynchronous; a seam for tests).
    lazy var makeCEFTab: (BrowserTabConfiguration) async throws -> any BrowserTab = { [chromium] in try await chromium.engine.makeUserTab($0) }
    /// Makes a Chromium page in the current turn while Chromium runs (`ChromiumNewTabNow`; a seam for tests).
    lazy var chromiumNow = ChromiumNow(chromium)
    /// The remote-localhost store and navigation guard of a Chromium page for
    /// a tab (`RemoteLocalhostService.configuration`). Nil result: the proxy
    /// could not start, so the page must not load (never this Mac's localhost).
    var configureBrowser: ((TabModel, URL?, BrowserTabConfiguration) async -> BrowserTabConfiguration?)?
    /// The omnibar's browser profile badge of tab `key` (nil: hidden).
    var profileBadge: ((String) -> BrowserProfileBadge?)?
    /// The menu of tab `key`'s browser profile badge.
    var profileBadgeMenu: ((String) -> NSMenu?)?
    /// The omnibar and tab-strip machine chip of tab `key` for a URL.
    var machineBadge: ((String, URL?) -> (text: String, help: String)?)?
    /// The tab with durable id `key` on any machine (`browserTabs` only knows the local daemon).
    var findTab: ((String) -> TabModel?)?
    /// A CEF page finished its asynchronous creation; panes showing `key` re-show.
    var onBrowserReady: ((String) -> Void)?
    /// Presentation changed: the blank-pane invariant, the input monitor and the browser host subscribe.
    let presentationChanges = PresentationChangeSubscribers()
    weak var sessionDelegate: (any TerminalSessionDelegate)?
    /// Routes app shortcuts before a Chromium page window sees them (a CEF page window is key, so `ShellWindow` never gets the key).
    weak var keyRouter: KeyRouter?
    /// A page's chrome hands the keyboard back to page `key` (find bar
    /// closed, address bar editing ended); the App routes it through the window's focus coordinator.
    var onPageFocusRequest: ((String) -> Void)?
    /// A provisional split's terminal tab got its daemon surface on a daemon (``awaitConfirm(_:of:daemon:)``).
    var onTerminalConfirmed: ((TabModel, DaemonService) -> Void)?
    /// A Ctrl-` stand-in's terminal became its daemon tab's (stand-in id, daemon tab id): the key holds follow it.
    var onStandInAdopted: ((String, String) -> Void)?
    /// Every new page's chrome gets this (the page info bubble's registry router).
    var onBrowserEntryCreated: ((BrowserEntry) -> Void)?
    /// The Extensions (puzzle) menu handler of Chromium tab `key` (the App's action registry, `ExtensionMenuRouter`).
    var makeExtensionMenuHandler: ((String) -> (any ExtensionMenuHandling)?)?
    /// Page `key`'s docked DevTools opened (and takes the keyboard) or closed; the App routes it through the window's focus coordinator.
    var onDevToolsChange: ((String, BrowserDevToolsState, Bool) -> Void)?

    /// The app's grid sender for every terminal it makes (``ResizeCoordinator``).
    let resizes: ResizeCoordinator
    /// Takes the daemon's stages of each key echo of a local terminal; set by the App.
    var terminalKeyStamps: (any TerminalKeyStampSink)?

    /// - Parameters:
    ///   - chromium: The Chromium engine's slot: its stores now, the engine (and the App's wiring) at its first read.
    ///   - fileInput: answers a WebKit browser tab's file input (the App's made-ahead panel; tests pass a stand-in).
    ///   - afterFrame: runs work once the current pass's frame committed (a stand-in's page follows the key's
    ///     frame); tests pass one that collects the work or runs it at once.
    ///   - resizes: The app's grid sender (`AppServices.resizes`); tests get their own.
    ///   - terminalModifiers: The terminals' one modifier watch on the app's input tap; tests without a tap pass none.
    ///   - terminalPointerFrames: The windows' pointer coalescers while `terminalPointerFrames` is on; nil otherwise.
    ///   - mainWork: The app's main-thread scheduler, for every terminal session it makes.
    ///   - deadlines: The app's one `MainDeadline` placer on `mainWork` (`AppServices.mainDeadlines`), for its WebKit tabs.
    ///   - appEvents: The app's one ``AppEvents`` (`AppServices.appEvents`), for its WebKit tabs' app-wide notices.
    ///   - imageCaches: The picture stores' full sizes: this Mac's budget shares with `memoryImageCaches` on, the
    ///     fixed sizes from before it otherwise (the default, which tests get).
    ///   - gpuResidency: The app's GPU memory release (``gpuResidency``); tests get none.
    ///   - webKitProcessReuse: Same-site WebKit tab processes above the renderer limit (`webKitSameSiteProcesses`);
    ///     nil, the default, gives every WebKit tab its own process.
    ///   - terminalExternalCursor: `terminalCursorLayer` is on (``terminalExternalCursor``); tests get Ghostty's cursor.
    ///   - streamFocus: The terminals' stream ranking while `terminalStreamPriority` is on; nil, the default, ranks none.
    init(daemon: DaemonService, chromium: ChromiumEngineSlot, fileInput: any WebFileInputAnswering,
         afterFrame: @escaping (@escaping @MainActor () -> Void) -> Void = { AfterFrameCommit().run($0) },
         resizes: ResizeCoordinator = ResizeCoordinator(), terminalModifiers: TerminalModifierWatch? = nil,
         terminalPointerFrames: FrameInputCoalescers? = nil, mainWork: MainWorkScheduler, deadlines: MainDeadlineScheduler,
         appEvents: AppEvents, imageCaches: ImageCacheShares = .legacy, gpuResidency: (any TerminalGPUResidency)? = nil,
         webKitProcessReuse: WebKitProcessReuse? = nil, terminalExternalCursor: Bool = false,
         streamFocus: TerminalStreamFocus? = nil) {
        self.imageCaches = imageCaches
        previews = PreviewImageCache(fullCapacityBytes: imageCaches.previewBytes, contents: .rebuildable, allocator: imageCaches.pictureAllocator)
        internalPagePictures = PreviewImageCache(fullCapacityBytes: imageCaches.internalPagePictureBytes, contents: .onlyCopy, allocator: imageCaches.pictureAllocator)
        pageThumbnails = PreviewImageCache(fullCapacityBytes: imageCaches.pageThumbnailBytes, contents: .onlyCopy, allocator: imageCaches.pictureAllocator)
        (self.daemon, self.terminalModifiers, self.chromium, self.resizes, self.mainWork) = (daemon, terminalModifiers, chromium, resizes, mainWork)
        self.terminalPointerFrames = terminalPointerFrames
        self.streamFocus = streamFocus
        self.gpuResidency = gpuResidency
        self.terminalExternalCursor = terminalExternalCursor
        normalWarmCapacity = SubsystemBudget.forThisMac(gpuResidentAvailable: gpuResidency != nil).warmTerminalSurfaces
        goneTabs = GoneTabWatch(mainWork: mainWork)
        webKit = WebKitEngine(fileInput: fileInput, stores: chromium.stores, energy: mainWork.energy, waitDeadlines: chromium.waitDeadlines,
                              deadlines: deadlines, appEvents: appEvents, processReuse: webKitProcessReuse)
        self.afterFrame = afterFrame
        browserTabs = BrowserTabService(daemon: daemon, chromium: chromium, mainWork: mainWork, deadlines: deadlines, appEvents: appEvents)
        wireNotices()
        _ = ledger.setCapacity(normalWarmCapacity)  // no surface yet: closes nothing
        warmBudgetDidChange(to: normalWarmCapacity)
    }

    var liveTerminalCount: Int { terminals.count }

    /// True when `key` has a live surface or page (showing it is cheap).
    func hasContent(for key: String) -> Bool { terminals[key] != nil || browsers[key] != nil }

    func existingTerminal(_ key: String) -> TerminalEntry? { terminals[key] }

    // MARK: Terminals

    /// The surface for a daemon terminal tab, created (attached) on demand
    /// over `daemon`'s socket (the local daemon, or a Cloud machine's link).
    func terminal(for tab: TabModel, daemon: DaemonService) -> TerminalEntry {
        let validity = Self.terminalValidity(tab, daemon: daemon)
        // A provisional split's view stays: its own tab's confirm attaches it (`awaitConfirm`).
        if let entry = terminals[tab.id], entry.validity == validity || entry.gate != nil {
            if entry.gate != nil, entry.confirming !== tab { awaitConfirm(entry, of: tab, daemon: daemon) } // a new record of the tab
            return entry
        }
        // The daemon's tab of a Ctrl-` stand-in (the terminal id that create chose): the stand-in's view, session and
        // input lane become this tab's, so the keys typed into it meanwhile reach the PTY in order and none is dropped.
        if let adopted = adoptStandIn(for: tab, daemon: daemon) { return adopted }
        let attachTarget = TerminalAttachment.Target(surface: tab.surface, terminalResourceID: tab.terminalResourceID,
                                                     generation: daemon.store.generation)
        // Daemon restarted or the tab's surface changed: the pane presenting the old view lets it go before it closes.
        // The new view of the same terminal (a daemon restart: a new generation) shows what the old one showed
        // until its own content draws (no empty pane between them); another terminal shows nothing of the old one.
        // The tab's terminal id, else its content id (a terminal the daemon still adopts has no runtime surface, so no
        // terminal id yet, but keeps its content id), else its surface handle.
        let identity = (tab.terminalResourceID ?? tab.snapshot.contentResourceID).map { "term:\($0.rawValue)" }
            ?? "surface:\(tab.surface.rawValue)"
        let carried = terminals[tab.id].flatMap { $0.terminalIdentity == identity ? $0.session.carriedFrame() : nil }
        discardTerminal(tab.id)
        let target = DaemonTerminalIO.Target(attachment: attachTarget, initialSize: tab.size ?? CellSize(cols: 80, rows: 24),
                                             cursorDefault: .user)
        // Paused (and not claiming geometry) until a visible pane presents it.
        let render = ledger.isRendering(tab.id)
        let gate = ProvisionalTab.isProvisional(surface: tab.surface) ? TerminalTargetGate() : nil, create = createTabs.waitingInterval(.terminal, tab: tab.id, surface: tab.surface.rawValue) // create: a new tab's, whose stages its view marks (NewTerminalTrace)
        let io = DaemonTerminalIO(target: target, resizes: resizes, visible: render, gate: gate, createIntent: create?.intentID ?? 0, creatingInput: gate.flatMap { gate in daemon.creatingInput(tab.terminalID) { gate.isResolved } },
                                  burstTrace: pageRequests.services?.burstTrace, policyBlocked: daemon.policyBlock.check,
                                  hangWatch: daemon.hangWatch,
                                  keyStamps: daemon.isLocal ? terminalKeyStamps : nil, streamFocus: streamFocus,
                                  connection: { try await daemon.machineConnection() })
        let session = makeSession(io: io, tab: tab, daemon: daemon); session.traceCreate(create, surface: tab.surface.rawValue)
        if let carried { session.holdCarriedFrame(carried) }
        let entry = TerminalEntry(validity: validity, session: session, io: io, themeKey: TerminalThemeKey(machine: daemon.machineID, tab: tab),
                                  store: daemon.store, surface: tab.surface, gate: gate, mainWork: mainWork)
        if gate != nil, let terminal = tab.terminalID { entry.standIn = .init(terminal: terminal, daemon: daemon) }
        entry.terminalIdentity = identity
        terminals[tab.id] = entry
        // The delegate builds a machine-aware link filter. Install it only
        // after this session can be resolved back to its owning tab.
        session.delegate = sessionDelegate
        goneTabs.track(tab.id, in: daemon.store) { [weak self] in self?.release($0) }
        if gate != nil { awaitConfirm(entry, of: tab, daemon: daemon) }
        session.isRenderingSuspended = !render
        session.releasesGPUWhilePaused = ledger.isAway(tab.id)
        contentDidMount(tab.id)
        return entry
    }

    /// Tab ids whose Ghostty surface has focus (first responder in the key window), for `debug.focus`.
    var focusedTerminalTabs: [String] {
        terminals.filter { $0.value.session.model.isFocused }.map(\.key).sorted()
    }

    /// The tab id whose surface is `session`.
    func tabKey(for session: TerminalSession) -> String? {
        terminals.first { $0.value.session === session }?.key
    }

    // MARK: Browsers

    func browser(for key: String, url: URL?, profile: BrowserProfileID? = nil) -> BrowserEntry {
        if let entry = browsers[key] { return entry }
        let profile = profile ?? browserProfile?(key) ?? .default
        if let page = sessionLocalAppPage(key: key, url: url, profile: profile) { return install(page, for: key) }
        let tab = webKit.makeWebKitTab(id: BrowserTabID(rawValue: key), profile: profile, initialURL: pageRequests.proxiedTabs.isProxied(key) ? nil : url)
        return install(tab, for: key)
    }

    func existingBrowser(_ key: String) -> BrowserEntry? { browsers[key] }

    /// The cmux page of a session-local tab (no daemon record, so no `TabModel` for ``makeAppPage(_:for:)``): only a
    /// machine's page can live in one (Open on <machine>). Its first open (`browser(for:url:profile:)`) and its wake
    /// after a release (`BrowserHibernation.restoreAppPage`) build it here.
    func sessionLocalAppPage(key: String, url: URL?, profile: BrowserProfileID? = nil) -> (any BrowserTab)? {
        MachineBrowserPages(cache: self).page(key: key, url: url, profile: profile ?? browserProfile?(key) ?? .default)
    }

    /// The page for a daemon browser tab on the engine its record names,
    /// written back to the record (url, title, favicon) while it lives.
    /// CEF starts lazily and creates tabs asynchronously (nil until ready); a New Tab page while it runs is made now.
    /// A Chromium record opens in WebKit when CEF is missing or fails to
    /// start (`ChromiumFallbackLog`: typed reason, one notice per process);
    /// the record keeps naming Chromium, so a build with CEF restores it.
    func browser(for tab: TabModel) -> BrowserEntry? {
        let key = tab.id
        claimAgentDriven(surface: tab.surface, key: key)
        // A close the daemon makes (`cmux tab close`, another client) frees the page too.
        goneTabs.track(key, in: browserTabs.daemon(for: tab).store) { [weak self] in self?.release($0) }
        if let entry = browsers[key] { return entry }
        if pageRequests.claimCloseOnArrival(tab.surface) {
            // Its page closed before the tab appeared (BrowserPageRequests): the tab closes after this presentation.
            mainWork.post(.visible, owner: "TabContentCache.closeOnArrival") { [weak self] in self?.pageRequests.closeTab(key) }
            return nil
        }
        if let adopted = pageRequests.takeAdoption(for: tab) { return tracked(install(adopted, for: key), tab) }
        // A stand-in's page and chrome come once its first frame (the tab selected on its themed pane) committed.
        if ProvisionalTab.isProvisional(surface: tab.surface), framedStandIns.insert(key).inserted, pendingBrowsers.insert(key).inserted {
            afterFrame { [weak self] in if self?.pendingBrowsers.remove(key) != nil { self?.onBrowserReady?(key) } }
            return nil
        }
        let url = MachineBrowserPages(cache: self).recordURL(tab) ?? recordURL(tab)
        // A browser tab on a Mac Screen address (dev builds before Mac Screen had its own tab
        // kind, or restored from then): the Mac Screen tab replaces it, waiting for Connect.
        if let url, MacScreenRecord.matches(url) {
            pageRequests.services?.macScreenTabs.replaceBrowserTab(key, url: url)
            return nil
        }
        if let page = appPage(for: tab, url: url) { return page }
        let origin = launchOrigin(of: tab)  // read once: the deferral and the page made now agree
        if let page = deferredPage(tab, url: url, origin: origin) { return page }  // after crashes, or hidden at launch
        if let read = enginesAwait, !read.isSignaled { return awaitLaunchRead(read, key) }
        guard tab.browserEngine == BrowserEngineTag.cef.rawValue else { return tracked(browserTabs.historyStarts.page(tab, url: url, cache: self) ?? browser(for: key, url: url), tab) }
        if let reason = browserTabs.cefUnavailable() { return fallBack(tab, url: url, reason: reason) }
        if !pendingBrowsers.contains(key), let page = ChromiumNewTabNow(cache: self).page(tab, url: url, origin: origin) { return tracked(install(page, for: key), tab) }
        guard pendingBrowsers.insert(key).inserted, cef.notePoint("page_task") else { return nil }
        // Off main until CEF's own main-thread steps (configuration, page creation); the cache's steps run in `startCEFPage`.
        Task { @concurrent [weak self] in await self?.startCEFPage(tab, key: key, url: url, origin: origin) }
        return nil
    }

    /// Makes Chromium page `key` for `tab`, made with `origin`, and installs it, or falls back to WebKit when CEF fails.
    private func startCEFPage(_ tab: TabModel, key: String, url: URL?, origin: BrowserTabOrigin) async {
        defer { pendingBrowsers.remove(key) }
        let page: any BrowserTab
        do {
            page = try await makeCEFTab(cef.noted("history", await browserTabs.historyStarts.chromium(tab, cef.noted("configured", await chromiumConfiguration(for: tab, key: key, url: url, origin: origin)), cache: self)))
        } catch {
            guard let tab = browserTabs.tabModel(key), browsers[key] == nil else { return }
            _ = fallBack(tab, url: url, reason: browserTabs.cefUnavailable() ?? .startFailed(String(describing: error)))
            onBrowserReady?(key)
            return
        }
        guard goneTabs.tracks(key) else { return page.close() } // closed while it started (release forgot it)
        let entry = install(page, for: key)
        // By id, not the captured TabModel: a tab moved while its page
        // started (`cmux browser open` then split) has a new model.
        browserTabs.track(page, tabID: key)
        if let tab = browserTabs.tabModel(key), let notice = browserTabs.takeNotice(for: tab) {
            entry.chrome.showNotice(notice)
        }
        onBrowserReady?(key)
    }

    /// No page yet: once `read` is done the page is made for the tab (shown or not) and panes showing it re-show,
    /// unless the tab was released first. One step per tab: a release forgets it, so a stale step does nothing.
    private func awaitLaunchRead(_ read: LaunchReadEvent, _ key: String) -> BrowserEntry? {
        guard awaitingRead.insert(key).inserted else { return nil }
        read.post { [weak self] in
            guard let self, awaitingRead.contains(key) else { return }
            let entry = tabModel(key).flatMap { browser(for: $0) }  // a Chromium page in creation reports when it is ready
            awaitingRead.remove(key)
            if entry != nil || !pendingBrowsers.contains(key) { onBrowserReady?(key) }
        }
        return nil
    }

    /// Returns once no launch read holds browser pages: at once when none does (callers that need a page now).
    func enginesReady() async {
        guard let read = enginesAwait, !read.isSignaled else { return }
        _ = try? await withOnceContinuation { (done: OnceContinuation<Void, OnceContinuationError>) in read.post { done.resume(returning: ()) } }
    }

    /// The URL a browser record may open here. A record from a remote
    /// machine's tree opens only web pages (`RemoteRelayPolicy`): a remote
    /// host must not make this Mac load `file:` or `javascript:` content or
    /// launch an app through a custom scheme.
    private func recordURL(_ tab: TabModel) -> URL? {
        guard let services = pageRequests.services, !services.machines.daemon(forTab: tab).isLocal else {
            return browserTabs.startURL(for: tab).flatMap(URL.init(string:))
        }
        return RemoteRelayPolicy.remoteBrowserURL(tab.url)
    }

    /// The Chromium configuration of `tab` showing `url`, made with `origin`, with its
    /// remote-localhost store. A failed proxy start leaves the page blank.
    private func chromiumConfiguration(for tab: TabModel, key: String, url: URL?, origin: BrowserTabOrigin) async -> BrowserTabConfiguration {
        await chromiumConfiguration(for: tab, base: BrowserTabConfiguration(id: BrowserTabID(rawValue: key), profile: browserProfile?(key) ?? .default,
                                                                            initialURL: url, origin: origin))
    }

    /// Re-creates Chromium page `key` in the other remote-localhost store
    /// with `url` (its navigation left the store; `BrowserTabIntent.rerouteStore`).
    /// The daemon record keeps the tab; the new page writes its URL back.
    func reroute(_ key: String, to url: URL) {
        guard let tab = tabModel(key), let entry = browsers[key], entry.tab.engineKind == .cef,
              pendingBrowsers.insert(key).inserted else { return }
        browserTabs.untrack(key)
        browsers.removeValue(forKey: key)?.close()
        Task { @concurrent [weak self] in await self?.restartCEFPage(tab, key: key, url: url) }
    }

    /// Makes Chromium page `key` again with `url` in its new store (``reroute(_:to:)``).
    private func restartCEFPage(_ tab: TabModel, key: String, url: URL) async {
        defer { pendingBrowsers.remove(key) }
        guard let page = try? await makeCEFTab(await chromiumConfiguration(for: tab, key: key, url: url, origin: .user)) else { return }
        install(page, for: key)
        browserTabs.track(page, tabID: key)
        onBrowserReady?(key)
    }

    /// Move Tab to Browser Profile (data-model.md 5): an engine fixes a page's store when it makes it, so `key`'s page is
    /// re-made in `profile` (its record already names it) and loads `url`; the old page closes now. History and form input
    /// stay with the old profile. A page made later (deferred, asleep, none yet) takes the profile from the record.
    func recreatePage(_ key: String, in profile: BrowserProfileID, url: URL) {
        guard let old = browsers[key]?.tab, !(old is DeferredBrowserTab), !(old is HibernatedBrowserTab) else { return }
        if old.engineKind == .cef { return reroute(key, to: url) }  // a new browser in the record's request context
        swapPage(key, with: webKit.makeWebKitTab(id: old.id, profile: profile, initialURL: url, zoom: old.state.zoom))
    }

    /// A WebKit page for a Chromium record, with the fallback recorded and the one-time notice shown when this is the first.
    private func fallBack(_ tab: TabModel, url: URL?, reason: CEFUnavailableReason) -> BrowserEntry {
        let fallbacks = browserTabs.fallbacks
        fallbacks.record(reason, source: .recordedTab, machine: browserTabs.daemon(for: tab).machineID, surface: tab.surface)
        return tracked(browserTabs.historyStarts.page(tab, url: url, cache: self) ?? browser(for: tab.id, url: url), tab)
    }

    /// Starts the record write-back and shows a pending fallback notice.
    private func tracked(_ entry: BrowserEntry, _ tab: TabModel) -> BrowserEntry {
        browserTabs.track(entry.tab, for: tab)
        if let notice = browserTabs.fallbacks.takeNotice(machine: browserTabs.daemon(for: tab).machineID, surface: tab.surface) {
            entry.chrome.showNotice(notice)
        }
        if let notice = browserTabs.takeNotice(for: tab) { entry.chrome.showNotice(notice) }
        return entry
    }

    /// Wraps a live page in chrome, keyed by tab id. Pages route their
    /// requests (links in new tabs, popups, `window.close()`) to
    /// `pageRequests`; Chromium pages route app shortcuts to `keyRouter`
    /// (their page window is key, so `ShellWindow` never sees the key).
    @discardableResult
    func install(_ page: any BrowserTab, for key: String) -> BrowserEntry {
        page.delegate = pageRequests
        if page.engineKind == .cef { page.keyRouter = keyRouter }
        (page as? CEFTab)?.devToolsObserver = self
        let incognito = chromium.stores.offTheRecord.isOffTheRecord(page.profileID) ? incognitoMemory : nil
        let entry = BrowserEntry(tab: page, suggestionEngine: suggestionEngine(forPage: page),
                                 history: incognito?.history ?? history(for: page.profileID), mainWork: mainWork, node: node(for: key))
        pageRequests.routeOmnibarOpens(of: entry.chrome, page: page)
        mount(entry, as: key)
        return entry
    }

    /// Binds `entry` to tab id `key`: everything of the chrome and the cache that names the tab,
    /// the app's hooks (`onBrowserEntryCreated`, which capture the tab) included. Runs again when a
    /// stand-in's entry moves to its daemon tab (`moveBrowser`): each hook replaces what it set.
    private func mount(_ entry: BrowserEntry, as key: String) {
        let page = entry.tab
        entry.chrome.addressBar.tabKey = key
        showPendingNotice(on: entry, key: key); MachineBrowserPages(cache: self).wireChip(entry, page: page, key: key)
        entry.chrome.onReturnFocusToPage = { [weak self] in self?.onPageFocusRequest?(key) }
        serveAppPages(entry, key: key)
        entry.chrome.addressBar.setProfileBadge(profileBadge?(key))
        entry.chrome.addressBar.profileBadgeMenu = { [weak self] in self?.profileBadgeMenu?(key) }
        onBrowserEntryCreated?(entry)
        if page.engineKind == .cef, let handler = makeExtensionMenuHandler?(key) {
            entry.extensionMenuHandler = handler
            entry.chrome.extensionMenuHandler = handler
        }
        if agentDrivenTabs.contains(key) { page.markAgentDriven() } else if page.isAgentDriven { agentDrivenTabs.insert(key) }
        pageRequests.proxiedTabs.adopt(store: (page as? CEFTab)?.machineStore, key: key)
        if page.engineKind == .cef { chromium.built?.mergeEvents(of: page, following: node(for: key)) } // page events by its node
        browsers[key] = entry
        (page as? CEFTab)?.publishRenderers(as: key, into: tabRenderers) { [weak self] in self?.browsers[key]?.tab === $0 }
        hibernation?.pageDidMount(key, page)
        pageInstalls.bump()
        // Pages are kept by hibernation, never by the terminal warm set.
        ledger.setRetained(key, false)
        contentDidMount(key)
    }

    /// Stand-in tab `key`'s page and chrome become daemon tab `tab`'s (`PaneBrowserTabOpener.openStandIn`), in the
    /// turn the store swaps the two: nothing is rebuilt or reloaded, and the pane that shows the
    /// stand-in keeps the same view when it moves to `tab`. False when the stand-in has no page
    /// (yet) or `tab` has one: `tab` then makes its own.
    func moveBrowser(_ key: String, to tab: TabModel) -> Bool {
        guard !pendingBrowsers.contains(key), browsers[tab.id] == nil, let entry = browsers.removeValue(forKey: key) else { return false }
        moveNode(key, to: tab.id) // the page's node goes with it
        release(key, displacing: false)
        mount(entry, as: tab.id)
        goneTabs.track(tab.id, in: browserTabs.daemon(for: tab).store) { [weak self] in self?.release($0) }
        _ = tracked(entry, tab)
        return true
    }

    /// Tab `key`'s node for the pane that selects it: a daemon tab whose Ctrl-` stand-in waits adopts it first, so the pane
    /// shows, once, the node the stand-in's content follows (`moveNode`; a node made first hid it for good: P0 resize).
    func selectedNode(for key: String) -> VisibilityNode {
        if tabNodes[key]?.node == nil, terminals[key] == nil, let link = terminals.values.lazy.compactMap(\.standIn).first(where: { $0.daemon?.store.tab(terminal: $0.terminal)?.id == key }),
           let daemon = link.daemon, let tab = daemon.store.tab(terminal: link.terminal) { _ = adoptStandIn(for: tab, daemon: daemon) }
        return node(for: key)
    }

    /// Stand-in tab `key`'s visibility node becomes `real`'s, unless `real` has one: the content moving with it keeps it.
    func moveNode(_ key: String, to real: String) {
        guard let node = tabNodes.removeValue(forKey: key)?.node, tabNodes[real]?.node == nil else { return }
        tabNodes[real] = WeakTabNode(node: node)
        daemon.trackVisibility(ofTab: real, node: node) // the daemon reports the node's visibility for `real` now
    }

    /// Swaps `tab`'s page for `page` (an adopted popup that arrived after the tab's placeholder page was created).
    func replacePage(of tab: TabModel, with page: any BrowserTab) {
        let key = tab.id
        browserTabs.untrack(key)
        browsers.removeValue(forKey: key)?.close()
        _ = tracked(install(page, for: key), tab)
        onBrowserReady?(key)
    }

    /// Replaces `key`'s page (hibernation, restore): the old page closes,
    /// the record write-back follows the new one, and panes showing `key`
    /// re-show with the new view. A page woken from hibernation passes the
    /// state it slept on (`asleep`): its omnibar shows that address from the first frame, not the new page's blank one.
    func swapPage(_ key: String, with page: any BrowserTab, asleep: BrowserTabState? = nil) {
        browserTabs.untrack(key)
        browsers.removeValue(forKey: key)?.close()
        installReplacement(page, for: key)
        if let asleep { browsers[key]?.chrome.holdAddress(whileWaking: asleep) }
        if !(page is HibernatedBrowserTab) {
            browserTabs.track(page, tabID: key)
        }
        onBrowserReady?(key)
    }

    /// The tab id whose page is `page`.
    func key(of page: any BrowserTab) -> String? {
        browsers.first { $0.value.tab === page }?.key
    }

    /// The tab closed: free everything it held (a conversation tab's view: `onRelease`).
    func release(_ key: String, displacing: Bool = true) { // displacing false: the pane keeps its view (a stand-in's moved to its daemon tab)
        onRelease?(key)
        // A stand-in's content moving to its daemon tab (`displacing` false) is no close: the wait follows the content.
        if displacing { createTabs.released(key) }
        if let owner = ledger.remove(key), displacing { presenters[owner]?.value?.surfaceWasDisplaced(key) }
        applyLifecycle(lifecycle.send(.removed(key)))
        pendingMounts[key] = nil; framedStandIns.remove(key); pendingBrowsers.remove(key); awaitingRead.remove(key); launchDeferredNodes[key] = nil
        hibernation?.forget(key); pageLifecycle?.remove(key)
        agentMarks.forget(key)
        pageRequests.services?.remoteViewPages.forget(key)
        terminals.removeValue(forKey: key)?.close()
        fontScaleWaits[key] = nil
        goneTabs.forget(key)
        browsers.removeValue(forKey: key)?.close()
        browserTabs.untrack(key)
        previews.remove(key)
        internalPagePictures.remove(key)
        pageThumbnails.remove(key)
        pageThumbnailVersions[key] = nil
        shownPages.remove(key)
        presentationChanges.notify(changed: [key])
    }

    // MARK: Visibility

    /// Tab `key`'s node in the visibility tree (p06-scheduler.md B): visible while the tab is selected
    /// in a visible pane (`PaneController.selectTabNode`), else hidden. Keyed by tab, as its surface
    /// is, so a tab moved to another pane keeps its node, and a closed tab's content going
    /// (`release`) leaves it.
    ///
    /// The cache holds nodes weakly: a node lives while the pane that selects its tab holds it, or a
    /// follower does. Hold the node for as long as you subscribe to it. A tab that nothing holds gets
    /// a new hidden node, which is its true state: no pane selects it.
    func node(for key: String) -> VisibilityNode {
        if let node = tabNodes[key]?.node { return node }
        let node = VisibilityNode("tab:\(key)", own: .hidden, parent: unselectedTabs)
        tabNodes[key] = WeakTabNode(node: node)
        daemon.trackVisibility(ofTab: key, node: node)  // the daemon holds a hidden tab's field events (frontend.visibility.set)
        if tabNodes.count >= tabNodesPruneAt {
            tabNodes = tabNodes.filter { $0.value.node != nil }
            tabNodesPruneAt = max(64, tabNodes.count * 2)
        }
        return node
    }

    private struct WeakTabNode {
        weak var node: VisibilityNode?
    }
}

/// A pane that shows cached content.
@MainActor
protocol SurfacePresenter: AnyObject {
    /// `key`'s view now belongs to another presenter, or its surface was
    /// destroyed. Drop the view if it is still installed here; do not withdraw or pause it.
    func surfaceWasDisplaced(_ key: String)
    /// The window it presents in, if any.
    var presentingWindow: NSWindow? { get }
    /// The size a surface it shows is laid out at, if known (the intent prewarm sizes a hidden page to it).
    var presentedContentSize: CGSize? { get }
}

extension SurfacePresenter {
    var presentingWindow: NSWindow? { nil }
    var presentedContentSize: CGSize? { nil }
}

extension PaneController {
    var presentingWindow: NSWindow? { view.window }
    var presentedContentSize: CGSize? { view.contentHost.bounds.size }
}

struct WeakPresenter {
    weak var value: (any SurfacePresenter)?
}
