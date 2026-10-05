import AppKit
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextTerminal
import Observation

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
    var browsers: [String: BrowserEntry] = [:]
    var ledger = SurfaceLedger<String, ObjectIdentifier>(capacity: WarmSetBudget.standard.terminalCapacity)
    var presenters: [ObjectIdentifier: WeakPresenter] = [:]
    /// Every tab's content phase and visibility generation (plans/cmux-next/tab-lifecycle.md):
    /// the only source of show and hide for terminal surfaces and pages (`TabContentCache+Lifecycle`).
    var lifecycle = ContentLifecycle<String>()
    /// Shown tabs whose content did not exist yet (a Chromium page being
    /// created): the token of their `mount`, answered when it installs.
    var pendingMounts: [String: ContentLifecycle<String>.Token] = [:]
    /// How many hidden terminal surfaces stay warm (memory budget; pressure).
    var warmBudget = WarmSetBudget.standard
    var onRelease: ((String) -> Void)?
    /// Hibernates hidden pages (time, memory pressure) and restores them.
    var hibernation: BrowserHibernation?
    /// Hibernated tabs, observed by the tab strips.
    let dormantTabs = DormantTabs()
    let previews = PreviewImageCache()
    /// Browser pages' hover card thumbnails, captured when a page leaves the
    /// screen (R131), at most `TabPreviewFitting.cachedPixelSize` each. Kept
    /// apart from `previews`, whose full-size page images hibernation shows.
    let pageThumbnails = PreviewImageCache(capacityBytes: 16 << 20)
    /// Pages revealed since their last hide: the next hide captures their
    /// thumbnail (`TabContentCache+Lifecycle`).
    var shownPages: Set<String> = []
    let webKit = WebKitEngine()
    let cef: CEFEngine
    /// Pages visited in the default browser profile, shared by its omnibars for suggestions and
    /// inline autocomplete (in memory, durable via `HistoryService`). Others: `history(for:)`.
    let history = InMemoryBrowserHistory()
    private(set) lazy var suggestionEngine = OmniboxSuggestionEngine(providers: [HistorySuggestionProvider(store: history)] + (extraSuggestionProviders?(.default) ?? []))
    var extraSuggestionProviders: ((BrowserProfileID) -> [any BrowserSuggestionProvider])? // bookmark rows per profile
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
    private(set) var browserTabs: BrowserTabService!
    /// Page-originated tab requests (new-tab links, popups, window.close).
    let pageRequests = BrowserPageRequests()
    private var pendingBrowsers: Set<String> = []
    /// Restored browser tabs start as `DeferredBrowserTab` (nothing loads)
    /// until the user reloads one: set after cmux quit unexpectedly twice in
    /// a row (`LaunchRecovery.restartedSafely`).
    var defersRestoredPages = false
    /// Tabs whose deferred page the user started.
    var startedDeferred: Set<String> = []
    /// Agent marks of tabs (`TabContentCache+AgentDriven`); kept across hibernation and restarts of the page.
    var agentMarks = TabAgentMarks()
    /// Creates a Chromium page (asynchronous; a seam for tests).
    lazy var makeCEFTab: (BrowserTabConfiguration) async throws -> any BrowserTab = { [cef] in
        try await cef.makeTab($0)
    }
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
    /// Presentation changed (for the blank-pane invariant).
    var onPresentationChange: (() -> Void)?
    weak var sessionDelegate: (any TerminalSessionDelegate)?
    /// Routes app shortcuts before a Chromium page window sees them (a CEF
    /// page window is key, so `ShellWindow` never gets the key).
    weak var keyRouter: KeyRouter?
    /// A page's chrome hands the keyboard back to page `key` (find bar
    /// closed, address bar editing ended); the App routes it through the
    /// window's focus coordinator.
    var onPageFocusRequest: ((String) -> Void)?
    /// Every new page's chrome gets this (the page info bubble's registry router).
    var onBrowserEntryCreated: ((BrowserEntry) -> Void)?
    /// The Extensions (puzzle) menu handler of Chromium tab `key` (the App's
    /// action registry, `ExtensionMenuRouter`).
    var makeExtensionMenuHandler: ((String) -> any ExtensionMenuHandling)?
    /// Page `key`'s docked DevTools opened (and takes the keyboard) or
    /// closed; the App routes it through the window's focus coordinator.
    var onDevToolsChange: ((String, BrowserDevToolsState, Bool) -> Void)?

    init(daemon: DaemonService, cef: CEFEngine = CEFEngine()) {
        self.daemon = daemon
        self.cef = cef
        browserTabs = BrowserTabService(daemon: daemon, cef: cef)
    }

    var liveTerminalCount: Int { terminals.count }

    /// True when `key` has a live surface or page (showing it is cheap).
    func hasContent(for key: String) -> Bool { terminals[key] != nil || browsers[key] != nil }

    func existingTerminal(_ key: String) -> TerminalEntry? { terminals[key] }

    // MARK: Terminals

    /// The surface for a daemon terminal tab, created (attached) on demand
    /// over `daemon`'s socket (the local daemon, or a Cloud machine's link).
    func terminal(for tab: TabModel, daemon: DaemonService) -> TerminalEntry {
        let validity = "\(daemon.machineID)#\(tab.id)#\(daemon.store.generation?.rawValue ?? "")#\(tab.surface.rawValue)"
        if let entry = terminals[tab.id], entry.validity == validity { return entry }
        if let stale = terminals.removeValue(forKey: tab.id) {
            // Daemon restarted or the tab's surface changed: the pane
            // presenting the old view lets it go before it closes.
            if let owner = ledger.remove(tab.id) { presenters[owner]?.value?.surfaceWasDisplaced(tab.id) }
            applyLifecycle(lifecycle.send(.removed(tab.id)))
            pendingMounts[tab.id] = nil
            stale.close()
        }
        let target = DaemonTerminalIO.Target(
            attachment: TerminalAttachment.Target(surface: tab.surface, terminalResourceID: tab.terminalResourceID,
                                                  generation: daemon.store.generation),
            initialSize: tab.size ?? CellSize(cols: 80, rows: 24), cursorDefault: .user
        )
        // Paused (and not claiming geometry) until a visible pane presents it.
        let render = ledger.isRendering(tab.id)
        let io = DaemonTerminalIO(target: target, visible: render, policyBlocked: daemon.policyBlock.check, endpoint: { try await daemon.endpoint() })
        let session = makeSession(io: io, tab: tab, daemon: daemon)
        let entry = TerminalEntry(validity: validity, session: session, io: io, themeKey: TerminalThemeKey(machine: daemon.machineID, tab: tab),
                                  store: daemon.store, surface: tab.surface)
        terminals[tab.id] = entry
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
        let tab = webKit.makeWebKitTab(BrowserTabConfiguration(id: BrowserTabID(rawValue: key), profile: profile, initialURL: url))
        return install(tab, for: key)
    }


    func existingBrowser(_ key: String) -> BrowserEntry? { browsers[key] }

    /// The page for a daemon browser tab on the engine its record names,
    /// written back to the record (url, title, favicon) while it lives.
    /// CEF starts lazily and creates tabs asynchronously: nil until ready.
    /// A Chromium record opens in WebKit when CEF is missing or fails to
    /// start (`ChromiumFallbackLog`: typed reason, one notice per process);
    /// the record keeps naming Chromium, so a build with CEF restores it.
    func browser(for tab: TabModel) -> BrowserEntry? {
        let key = tab.id
        claimAgentDriven(surface: tab.surface, key: key)
        if let entry = browsers[key] { return entry }
        if pageRequests.claimCloseOnArrival(tab.surface) {
            // Its page closed before the tab appeared (BrowserPageRequests).
            let key = tab.id
            Task { @MainActor [weak self] in self?.pageRequests.closeTab(key) }
            return nil
        }
        if let adopted = pageRequests.takeAdoption(for: tab.surface) {
            return tracked(install(adopted, for: key), tab)
        }
        let url = recordURL(tab)
        if let page = appPage(for: tab, url: url) { return page }
        if defersRestoredPages, !startedDeferred.contains(key), !browserTabs.openedSurfaces.contains(tab.surface) {
            return deferred(tab, url: url)
        }
        guard tab.browserEngine == BrowserEngineTag.cef.rawValue else { return tracked(browser(for: key, url: url), tab) }
        if let reason = browserTabs.cefUnavailable() { return fallBack(tab, url: url, reason: reason) }
        guard pendingBrowsers.insert(key).inserted else { return nil }
        Task {
            defer { pendingBrowsers.remove(key) }
            let page: any BrowserTab
            do {
                page = try await makeCEFTab(await chromiumConfiguration(for: tab, key: key, url: url))
            } catch {
                guard let tab = browserTabs.tabModel(key), browsers[key] == nil else { return }
                _ = fallBack(tab, url: url, reason: browserTabs.cefUnavailable() ?? .startFailed(String(describing: error)))
                onBrowserReady?(key)
                return
            }
            let entry = install(page, for: key)
            // By id, not the captured TabModel: a tab moved while its page
            // started (`cmux browser open` then split) has a new model.
            browserTabs.track(page, tabID: key)
            if let surface = browserTabs.tabModel(key)?.surface, let notice = browserTabs.takeNotice(for: surface) {
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

    /// A WebKit page for a Chromium record, with the fallback recorded and
    /// the one-time notice shown when this is the first.
    private func fallBack(_ tab: TabModel, url: URL?, reason: CEFUnavailableReason) -> BrowserEntry {
        let fallbacks = browserTabs.fallbacks
        fallbacks.record(reason, source: .recordedTab, surface: tab.surface)
        return tracked(browser(for: tab.id, url: url), tab)
    }

    /// Starts the record write-back and shows a pending fallback notice.
    private func tracked(_ entry: BrowserEntry, _ tab: TabModel) -> BrowserEntry {
        browserTabs.track(entry.tab, for: tab)
        if let notice = browserTabs.fallbacks.takeNotice(for: tab.surface) { entry.chrome.showNotice(notice) }
        if let notice = browserTabs.takeNotice(for: tab.surface) { entry.chrome.showNotice(notice) }
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
        let incognito = OffTheRecordProfiles.shared.isOffTheRecord(page.profileID) ? incognitoMemory : nil
        let entry = BrowserEntry(tab: page, suggestionEngine: incognito?.suggestions ?? suggestions(for: page.profileID),
                                 history: incognito?.history ?? history(for: page.profileID))
        entry.chrome.onReturnFocusToPage = { [weak self] in self?.onPageFocusRequest?(key) }
        pageRequests.routeOmnibarOpens(of: entry.chrome, page: page)
        serveAppPages(entry, key: key)
        entry.chrome.machineBadge = { [weak self] url in self?.machineBadge?(key, url) }
        entry.chrome.addressBar.setProfileBadge(profileBadge?(key))
        entry.chrome.addressBar.profileBadgeMenu = { [weak self] in self?.profileBadgeMenu?(key) }
        onBrowserEntryCreated?(entry)
        if page.engineKind == .cef, let handler = makeExtensionMenuHandler?(key) {
            entry.extensionMenuHandler = handler
            entry.chrome.extensionMenuHandler = handler
        }
        if agentDrivenTabs.contains(key) { page.markAgentDriven() } else if page.isAgentDriven { agentDrivenTabs.insert(key) }
        browsers[key] = entry
        pageInstalls.bump()
        // Pages are kept by hibernation, never by the terminal warm set.
        ledger.setRetained(key, false)
        contentDidMount(key)
        return entry
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
    /// re-show with the new view.
    func swapPage(_ key: String, with page: any BrowserTab) {
        browserTabs.untrack(key)
        browsers.removeValue(forKey: key)?.close()
        install(page, for: key)
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
    func release(_ key: String) {
        onRelease?(key)
        if let owner = ledger.remove(key) { presenters[owner]?.value?.surfaceWasDisplaced(key) }
        applyLifecycle(lifecycle.send(.removed(key)))
        pendingMounts[key] = nil
        hibernation?.forget(key)
        agentMarks.forget(key)
        pageRequests.services?.remoteViewPages.forget(key)
        terminals.removeValue(forKey: key)?.close()
        browsers.removeValue(forKey: key)?.close()
        browserTabs.untrack(key)
        previews.remove(key)
        pageThumbnails.remove(key)
        shownPages.remove(key)
        onPresentationChange?()
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

extension TabContentCache: BrowserDevToolsObserving {
    func browserTab(_ tab: any BrowserTab, devToolsDidChange state: BrowserDevToolsState, focused: Bool) {
        guard let key = key(of: tab) else { return }
        onDevToolsChange?(key, state, focused)
    }
}
