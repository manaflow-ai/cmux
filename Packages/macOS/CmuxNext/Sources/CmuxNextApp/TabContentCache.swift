import AppKit
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextMacScreen
import CmuxNextRemote
import CmuxNextTerminal
import CmuxNextWakeups
import Observation
import os

private let fallbackLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "browser.engine")

/// Owns every terminal surface and browser page in the process
/// (architecture.md 4). Surfaces are keyed by tab, not by pane: a tab moved
/// to another pane keeps its surface and the destination pane reparents the
/// view (`SurfaceLedger`). Surfaces exist for tabs presented on screen or in
/// the keep-alive band (off-screen columns within one viewport width, paused)
/// plus an LRU of 8 recently hidden ones; older hidden surfaces are destroyed and re-attach
/// from the daemon replay when shown. Previews of destroyed surfaces stay in a 32 MB image LRU.
final class TabContentCache {
    private let daemon: DaemonService
    var terminals: [String: TerminalEntry] = [:]
    var browsers: [String: BrowserEntry] = [:] { didSet { if browsers.count != oldValue.count { pageRequests.media.tabsChanged() } } }
    var ledger = SurfaceLedger<String, ObjectIdentifier>(capacity: WarmSetBudget.standard.terminalCapacity)
    var presenters: [ObjectIdentifier: WeakPresenter] = [:]
    /// Every tab's content phase and visibility generation (plans/cmux-next/tab-lifecycle.md):
    /// the only source of show and hide for terminal surfaces and pages (`TabContentCache+Lifecycle`).
    var lifecycle = ContentLifecycle<String>()
    /// Shown tabs whose content does not exist yet (a Chromium page being created): their `mount` token, answered at install.
    var pendingMounts: [String: ContentLifecycle<String>.Token] = [:]
    /// How many hidden terminal surfaces stay warm (memory budget; pressure).
    var warmBudget = WarmSetBudget.standard
    /// Set while a smaller warm budget evicts: surfaces close at once, with no last picture.
    var evictsAtOnce = false
    var onRelease: ((String) -> Void)?
    /// Hibernates hidden pages (time, memory pressure) and restores them.
    var hibernation: BrowserHibernation?
    /// Hibernated tabs, observed by the tab strips.
    let dormantTabs = DormantTabs()
    let previews = PreviewImageCache()
    /// Evicted terminals' last frames: shown at once when the terminal is shown again, pictured
    /// on demand for its hover card.
    var lastFrames = TerminalLastFrames()
    /// Releases terminals whose daemon tree dropped their tab (a closed workspace).
    let goneTabs = GoneTabWatch()
    /// Browser pages' hover card thumbnails (R131), at most `TabPreviewFitting.cachedPixelSize`
    /// each, with the page version each shows (`pageVersion`): a page is captured again only when
    /// its version moved. Kept apart from `previews`, whose full-size page images hibernation shows.
    let pageThumbnails = PreviewImageCache(capacityBytes: 16 << 20)
    var pageThumbnailVersions: [String: Int] = [:]
    var pageCapturesInFlight: Set<String> = []
    /// How long a leave capture may take before its thumbnail is dropped
    /// (the capture runs on the main thread). Tests that do not test this
    /// deadline use the shared 30 s test configuration.
    var pageCaptureDeadline: Duration = .seconds(2)
    /// Pages revealed since their last hide: the next hide captures their
    /// thumbnail (`TabContentCache+Lifecycle`).
    var shownPages: Set<String> = []
    /// Over the Chromium engine's stores, so both engines share them (``BrowserSharedStores``).
    let webKit: WebKitEngine
    let cef: CEFEngine
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
        didSet { if pendingBrowsers.isEmpty, !oldValue.isEmpty { onPagesSettled?() } }
    }
    /// No Chromium page is being created any more (ChromiumWarmup's spare window).
    var onPagesSettled: (@MainActor () -> Void)?
    private var framedStandIns: Set<String> = [] // stand-in tabs whose page waited for their first frame
    /// Runs work after the current pass's frame committed (`AfterFrameCommit`); tests pass their own.
    private let afterFrame: (@escaping @MainActor () -> Void) -> Void
    /// Restored tabs whose page waits for Reload (`DeferredBrowserTab`, one notice on that tab):
    /// the pages a run that ended early in a restart loop had started (`LaunchRecovery.crashedPages`).
    /// Every other restored tab loads when it shows.
    var crashedPages: Set<String> = []
    /// A restored tab (not opened in this run) started its page (`AppRunMarker.notePageStarted`).
    var onRestoredPageStart: ((String) -> Void)?
    /// Tabs whose deferred page the user started.
    var startedDeferred: Set<String> = []
    /// Agent marks of tabs (`TabContentCache+AgentDriven`); kept across hibernation and restarts of the page.
    var agentMarks = TabAgentMarks()
    /// Creates a Chromium page (asynchronous; a seam for tests).
    lazy var makeCEFTab: (BrowserTabConfiguration) async throws -> any BrowserTab = { [cef] in try await cef.makeUserTab($0) }
    /// Makes a Chromium page in the current turn while Chromium runs (`ChromiumNewTabNow`; a seam for tests).
    lazy var chromiumNow = ChromiumNow(cef)
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
    /// The tab with durable id `key` on any machine (`browserTabs` only
    /// knows the local daemon).
    var findTab: ((String) -> TabModel?)?
    /// A CEF page finished its asynchronous creation; panes showing `key` re-show.
    var onBrowserReady: ((String) -> Void)?
    /// Presentation changed: the blank-pane invariant, the input monitor and the browser host subscribe.
    let presentationChanges = PresentationChangeSubscribers()
    weak var sessionDelegate: (any TerminalSessionDelegate)?
    /// Routes app shortcuts before a Chromium page window sees them (a CEF
    /// page window is key, so `ShellWindow` never gets the key).
    weak var keyRouter: KeyRouter?
    /// A page's chrome hands the keyboard back to page `key` (find bar
    /// closed, address bar editing ended); the App routes it through the
    /// window's focus coordinator.
    var onPageFocusRequest: ((String) -> Void)?
    /// A provisional split's terminal tab got its daemon surface on a daemon (``awaitConfirm(_:of:daemon:)``).
    var onTerminalConfirmed: ((TabModel, DaemonService) -> Void)?
    /// Every new page's chrome gets this (the page info bubble's registry router).
    var onBrowserEntryCreated: ((BrowserEntry) -> Void)?
    /// The Extensions (puzzle) menu handler of Chromium tab `key` (the App's
    /// action registry, `ExtensionMenuRouter`).
    var makeExtensionMenuHandler: ((String) -> (any ExtensionMenuHandling)?)?
    /// Page `key`'s docked DevTools opened (and takes the keyboard) or
    /// closed; the App routes it through the window's focus coordinator.
    var onDevToolsChange: ((String, BrowserDevToolsState, Bool) -> Void)?

    /// The app's grid sender for every terminal it makes (``ResizeCoordinator``).
    let resizes: ResizeCoordinator

    /// - Parameters:
    ///   - fileInput: answers a WebKit browser tab's file input (the App's made-ahead panel; tests pass a stand-in).
    ///   - afterFrame: runs work once the current pass's frame committed (a stand-in's page follows the key's
    ///     frame); tests pass one that collects the work or runs it at once.
    ///   - resizes: The app's grid sender (`AppServices.resizes`); tests get their own.
    init(daemon: DaemonService, cef: CEFEngine = CEFEngine(stores: .inMemory(), signInCallbacks: CEFSignInCallbacks()), fileInput: any WebFileInputAnswering,
         afterFrame: @escaping (@escaping @MainActor () -> Void) -> Void = { AfterFrameCommit().run($0) },
         resizes: ResizeCoordinator = ResizeCoordinator()) {
        self.daemon = daemon
        self.cef = cef
        webKit = WebKitEngine(fileInput: fileInput, stores: cef.stores)
        self.afterFrame = afterFrame
        self.resizes = resizes
        browserTabs = BrowserTabService(daemon: daemon, cef: cef)
        wireNotices()
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
        let attachTarget = TerminalAttachment.Target(surface: tab.surface, terminalResourceID: tab.terminalResourceID,
                                                     generation: daemon.store.generation)
        if let stale = terminals.removeValue(forKey: tab.id) {
            // Daemon restarted or the tab's surface changed: the pane
            // presenting the old view lets it go before it closes.
            if let owner = ledger.remove(tab.id) { presenters[owner]?.value?.surfaceWasDisplaced(tab.id) }
            applyLifecycle(lifecycle.send(.removed(tab.id)))
            pendingMounts[tab.id] = nil
            stale.close()
        }
        let target = DaemonTerminalIO.Target(attachment: attachTarget, initialSize: tab.size ?? CellSize(cols: 80, rows: 24),
                                             cursorDefault: .user)
        // Paused (and not claiming geometry) until a visible pane presents it.
        let render = ledger.isRendering(tab.id)
        let gate = ProvisionalTab.isProvisional(surface: tab.surface) ? TerminalTargetGate() : nil
        let io = DaemonTerminalIO(target: target, resizes: resizes, visible: render, gate: gate, creatingInput: gate.flatMap { gate in daemon.creatingInput(tab.terminalID) { gate.isResolved } },
                                  burstTrace: pageRequests.services?.burstTrace, policyBlocked: daemon.policyBlock.check,
                                  endpoint: { try await daemon.endpoint() })
        let session = makeSession(io: io, tab: tab, daemon: daemon)
        let entry = TerminalEntry(validity: validity, session: session, io: io, themeKey: TerminalThemeKey(machine: daemon.machineID, tab: tab),
                                  store: daemon.store, surface: tab.surface, gate: gate)
        terminals[tab.id] = entry
        // The delegate builds a machine-aware link filter. Install it only
        // after this session can be resolved back to its owning tab.
        session.delegate = sessionDelegate
        goneTabs.track(tab.id, in: daemon.store) { [weak self] in self?.release($0) }
        if gate != nil { awaitConfirm(entry, of: tab, daemon: daemon) }
        session.isRenderingSuspended = !render
        contentDidMount(tab.id)
        return entry
    }

    /// Tab ids whose Ghostty surface has focus (first responder in the key
    /// window), for `debug.focus`.
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
        if let page = MachineBrowserPages(cache: self).page(key: key, url: url, profile: profile) { return install(page, for: key) }
        let tab = webKit.makeWebKitTab(id: BrowserTabID(rawValue: key), profile: profile, initialURL: pageRequests.proxiedTabs.isProxied(key) ? nil : url)
        return install(tab, for: key)
    }

    func existingBrowser(_ key: String) -> BrowserEntry? { browsers[key] }

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
            // Its page closed before the tab appeared (BrowserPageRequests).
            Task { @MainActor [weak self] in self?.pageRequests.closeTab(key) }
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
        if !browserTabs.wasOpenedHere(tab) {
            if crashedPages.contains(key), !startedDeferred.contains(key) { return deferred(tab, url: url) }
            onRestoredPageStart?(key)
        }
        guard tab.browserEngine == BrowserEngineTag.cef.rawValue else { return tracked(browserTabs.historyStarts.page(tab, url: url, cache: self) ?? browser(for: key, url: url), tab) }
        if let reason = browserTabs.cefUnavailable() { return chromiumUnavailable(tab, url: url, reason: reason) }
        if !pendingBrowsers.contains(key), let page = ChromiumNewTabNow(cache: self).page(tab, url: url) { return tracked(install(page, for: key), tab) }
        guard pendingBrowsers.insert(key).inserted, cef.notePoint("page_task") else { return nil }
        Task {
            defer { pendingBrowsers.remove(key) }
            let page: any BrowserTab
            do {
                page = try await makeCEFTab(cef.noted("history", await browserTabs.historyStarts.chromium(tab, cef.noted("configured", await chromiumConfiguration(for: tab, key: key, url: url)), cache: self)))
            } catch {
                guard let tab = browserTabs.tabModel(key), browsers[key] == nil else { return }
                _ = chromiumUnavailable(tab, url: url, reason: browserTabs.cefUnavailable() ?? .startFailed(String(describing: error)))
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
        return nil
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

    /// The Chromium configuration of `tab` showing `url`, with its
    /// remote-localhost store. A failed proxy start leaves the page blank.
    private func chromiumConfiguration(for tab: TabModel, key: String, url: URL?) async -> BrowserTabConfiguration {
        await chromiumConfiguration(for: tab, base: BrowserTabConfiguration(
            id: BrowserTabID(rawValue: key), profile: browserProfile?(key) ?? .default, initialURL: url))
    }

    /// `base` with the remote-localhost store of `tab` (every Chromium page a
    /// tab gets goes through here, a hibernated page waking included). A
    /// failed proxy start leaves the page blank, never on this Mac's localhost.
    func chromiumConfiguration(for tab: TabModel?, base: BrowserTabConfiguration) async -> BrowserTabConfiguration {
        guard let tab, let configureBrowser else { return base }
        if let configured = await configureBrowser(tab, base.initialURL, base) { return configured }
        var blank = base
        blank.initialURL = nil
        blank.restoreState = nil
        blank.navigationGuard = .noLoopback
        return blank
    }

    /// The tab with durable id `key` on any machine.
    func tabModel(_ key: String) -> TabModel? {
        browserTabs.tabModel(key) ?? findTab?(key)
    }

    /// Re-creates Chromium page `key` in the other remote-localhost store
    /// with `url` (its navigation left the store; `BrowserTabIntent.rerouteStore`).
    /// The daemon record keeps the tab; the new page writes its URL back.
    func reroute(_ key: String, to url: URL) {
        guard let tab = tabModel(key), let entry = browsers[key], entry.tab.engineKind == .cef,
              pendingBrowsers.insert(key).inserted else { return }
        browserTabs.untrack(key)
        browsers.removeValue(forKey: key)?.close()
        Task {
            defer { pendingBrowsers.remove(key) }
            guard let page = try? await makeCEFTab(await chromiumConfiguration(for: tab, key: key, url: url)) else { return }
            install(page, for: key)
            browserTabs.track(page, tabID: key)
            onBrowserReady?(key)
        }
    }

    /// Move Tab to Browser Profile (data-model.md 5): an engine fixes a page's store when it makes it, so `key`'s page is
    /// re-made in `profile` (its record already names it) and loads `url`; the old page closes now. History and form input
    /// stay with the old profile. A page made later (deferred, asleep, none yet) takes the profile from the record.
    func recreatePage(_ key: String, in profile: BrowserProfileID, url: URL) {
        guard let old = browsers[key]?.tab, !(old is DeferredBrowserTab), !(old is HibernatedBrowserTab) else { return }
        if old.engineKind == .cef { return reroute(key, to: url) }  // a new browser in the record's request context
        swapPage(key, with: webKit.makeWebKitTab(id: old.id, profile: profile, initialURL: url, zoom: old.state.zoom))
    }

    /// A WebKit page for a Chromium record, with the fallback recorded and
    /// the one-time notice shown when this is the first.
    func fallBack(_ tab: TabModel, url: URL?, reason: CEFUnavailableReason) -> BrowserEntry {
        // The page loads again in WebKit, without Chromium's cookies (a second copy of the app,
        // whose Chromium cannot start while the first holds its profile, shows signed-out pages).
        let tabID = tab.id, code = reason.code
        fallbackLogger.notice("tab \(tabID, privacy: .public) loads in WebKit: Chromium unavailable (\(code, privacy: .public)); its page reloads without Chromium's cookies")
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
        let incognito = cef.stores.offTheRecord.isOffTheRecord(page.profileID) ? incognitoMemory : nil
        let entry = BrowserEntry(tab: page, suggestionEngine: suggestionEngine(forPage: page),
                                 history: incognito?.history ?? history(for: page.profileID))
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
        browsers[key] = entry
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
        release(key, displacing: false)
        mount(entry, as: tab.id)
        goneTabs.track(tab.id, in: browserTabs.daemon(for: tab).store) { [weak self] in self?.release($0) }
        _ = tracked(entry, tab)
        return true
    }

    /// Swaps `tab`'s page for `page` (an adopted popup that arrived after
    /// the tab's placeholder page was created).
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
    /// state it slept on (`asleep`): its omnibar shows that address from the
    /// first frame, not the new page's blank one.
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
        // A closed tab is mirrored nowhere any more (`TabMirrors`); a stand-in moving to its daemon tab keeps nothing to drop.
        if displacing { pageRequests.services?.tabMirrors.remove(key) }
        if let owner = ledger.remove(key), displacing { presenters[owner]?.value?.surfaceWasDisplaced(key) }
        applyLifecycle(lifecycle.send(.removed(key)))
        pendingMounts[key] = nil; framedStandIns.remove(key); pendingBrowsers.remove(key)
        hibernation?.forget(key)
        agentMarks.forget(key)
        pageRequests.services?.remoteViewPages.forget(key)
        terminals.removeValue(forKey: key)?.close()
        goneTabs.forget(key)
        browsers.removeValue(forKey: key)?.close()
        browserTabs.untrack(key)
        previews.remove(key)
        pageThumbnails.remove(key)
        pageThumbnailVersions[key] = nil
        shownPages.remove(key)
        presentationChanges.notify(changed: [key])
    }
}

/// A pane that shows cached content.
@MainActor
protocol SurfacePresenter: AnyObject {
    /// `key`'s view now belongs to another presenter, or its surface was
    /// destroyed. Drop the view if it is still installed here; do not
    /// withdraw or pause it.
    func surfaceWasDisplaced(_ key: String)
}

struct WeakPresenter {
    weak var value: (any SurfacePresenter)?
}
