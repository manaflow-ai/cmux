import AppKit
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextTerminal
import Observation

/// Owns every terminal surface and browser page in the process
/// (architecture.md 4). Surfaces are keyed by tab, not by pane: a tab moved
/// to another pane keeps its surface and the destination pane reparents the
/// view (`SurfaceLedger`). Surfaces exist for tabs presented on screen or in
/// the keep-alive band (off-screen columns within one viewport width, paused)
/// plus an LRU of 8 recently hidden ones; older hidden surfaces are destroyed and re-attach
/// from the daemon replay when shown. Previews of destroyed surfaces stay in
/// a 32 MB image LRU.
final class TabContentCache {
    private let daemon: DaemonService
    private var terminals: [String: TerminalEntry] = [:]
    private var browsers: [String: BrowserEntry] = [:]
    private var ledger = SurfaceLedger<String, ObjectIdentifier>(capacity: 8)
    private var presenters: [ObjectIdentifier: WeakPresenter] = [:]
    let previews = PreviewImageCache()
    let webKit = WebKitEngine()
    let cef = CEFEngine()
    /// Pages visited this session, shared by every omnibar for suggestions
    /// and inline autocomplete (in memory; not persisted yet).
    let history = InMemoryBrowserHistory()
    private(set) lazy var suggestionEngine = OmniboxSuggestionEngine(providers: [HistorySuggestionProvider(store: history)])
    private(set) var browserTabs: BrowserTabService!
    /// Page-originated tab requests (new-tab links, popups, window.close).
    let pageRequests = BrowserPageRequests()
    private var pendingBrowsers: Set<String> = []
    /// Restored browser tabs start as `DeferredBrowserTab` (nothing loads)
    /// until the user reloads one: set after cmux quit unexpectedly twice in
    /// a row (`LaunchRecovery.restartedSafely`).
    var defersRestoredPages = false
    /// Tabs whose deferred page the user started.
    private var startedDeferred: Set<String> = []
    /// Creates a Chromium page (asynchronous; a seam for tests).
    lazy var makeCEFTab: (BrowserTabConfiguration) async throws -> any BrowserTab = { [cef] in
        try await cef.makeTab($0)
    }
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

    init(daemon: DaemonService) {
        self.daemon = daemon
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
            stale.close()
        }
        let target = DaemonTerminalIO.Target(
            attachment: TerminalAttachment.Target(surface: tab.surface, terminalResourceID: tab.terminalResourceID,
                                                  generation: daemon.store.generation),
            initialSize: tab.size ?? CellSize(cols: 80, rows: 24)
        )
        // Paused (and not claiming geometry) until a visible pane presents it.
        let render = ledger.isRendering(tab.id)
        let io = DaemonTerminalIO(target: target, visible: render, endpoint: { try await daemon.endpoint() })
        let session = TerminalSession(io: io, ownsGeometry: true)
        session.delegate = sessionDelegate
        let entry = TerminalEntry(validity: validity, session: session, io: io)
        terminals[tab.id] = entry
        session.isRenderingSuspended = !render
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

    func browser(for key: String, url: URL?) -> BrowserEntry {
        if let entry = browsers[key] { return entry }
        let tab = webKit.makeWebKitTab(BrowserTabConfiguration(id: BrowserTabID(rawValue: key), initialURL: url))
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
        let url = tab.url.flatMap(URL.init(string:))
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
                page = try await makeCEFTab(BrowserTabConfiguration(id: BrowserTabID(rawValue: key), initialURL: url))
            } catch {
                guard let tab = browserTabs.tabModel(key), browsers[key] == nil else { return }
                _ = fallBack(tab, url: url, reason: browserTabs.cefUnavailable() ?? .startFailed(String(describing: error)))
                onBrowserReady?(key)
                return
            }
            install(page, for: key)
            // By id, not the captured TabModel: a tab moved while its page
            // started (`cmux browser open` then split) has a new model.
            browserTabs.track(page, tabID: key)
            onBrowserReady?(key)
        }
        return nil
    }

    /// A page that loads nothing until the user reloads it; then the real
    /// page replaces it (same key, same record).
    private func deferred(_ tab: TabModel, url: URL?) -> BrowserEntry {
        let key = tab.id
        let engine: BrowserEngineKind = tab.browserEngine == BrowserEngineTag.cef.rawValue ? .cef : .webkit
        let page = DeferredBrowserTab(id: BrowserTabID(rawValue: key), engine: engine, url: url, title: tab.title.isEmpty ? nil : tab.title)
        page.onStart = { [weak self] url in self?.startDeferred(key, url: url) }
        let entry = install(page, for: key)
        entry.chrome.showNotice(CrashStrings.deferredPageNotice)
        return entry
    }

    private func startDeferred(_ key: String, url: URL?) {
        startedDeferred.insert(key)
        browsers.removeValue(forKey: key)?.close()
        guard let tab = browserTabs.tabModel(key) else { return }
        if let entry = browser(for: tab), let url, url.absoluteString != tab.url { entry.tab.load(url) }
        onBrowserReady?(key)
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
        return entry
    }

    /// Wraps a live page in chrome, keyed by tab id. Pages route their
    /// requests (links in new tabs, popups, `window.close()`) to
    /// `pageRequests`; Chromium pages route app shortcuts to `keyRouter`
    /// (their page window is key, so `ShellWindow` never sees the key).
    @discardableResult
    private func install(_ page: any BrowserTab, for key: String) -> BrowserEntry {
        page.delegate = pageRequests
        if page.engineKind == .cef { page.keyRouter = keyRouter }
        (page as? CEFTab)?.devToolsObserver = self
        let entry = BrowserEntry(tab: page, suggestionEngine: suggestionEngine, history: history)
        entry.chrome.onReturnFocusToPage = { [weak self] in self?.onPageFocusRequest?(key) }
        onBrowserEntryCreated?(entry)
        if page.engineKind == .cef, let handler = makeExtensionMenuHandler?(key) {
            entry.extensionMenuHandler = handler
            entry.chrome.extensionMenuHandler = handler
        }
        browsers[key] = entry
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

    /// The tab id whose page is `page`.
    func key(of page: any BrowserTab) -> String? {
        browsers.first { $0.value.tab === page }?.key
    }

    // MARK: Presentation and lifetime

    /// `presenter` shows `key` (its view is, or is about to be, in the
    /// presenter's hierarchy). Takes the surface from any previous presenter.
    func present(_ key: String, by presenter: any SurfacePresenter, presence: SurfacePresence) {
        let owner = ObjectIdentifier(presenter)
        presenters[owner] = WeakPresenter(value: presenter)
        apply(ledger.present(key, by: owner, presence: presence))
    }

    /// `presenter` stopped showing `key`. Ignored when another presenter
    /// took it meanwhile (the tab moved there).
    func withdraw(_ key: String, by presenter: any SurfacePresenter) {
        apply(ledger.withdraw(key, by: ObjectIdentifier(presenter)))
    }

    /// `presenter` scrolled on screen, into the keep-alive band, or away.
    func setPresence(_ presence: SurfacePresence, presenter: any SurfacePresenter) {
        apply(ledger.setPresence(presence, owner: ObjectIdentifier(presenter)))
    }

    /// `presenter` is going away.
    func removePresenter(_ presenter: any SurfacePresenter) {
        let owner = ObjectIdentifier(presenter)
        apply(ledger.removeOwner(owner))
        presenters[owner] = nil
    }

    /// The pane presenting `key`, if any.
    func presenter(of key: String) -> (any SurfacePresenter)? {
        ledger.owner(of: key).flatMap { presenters[$0]?.value }
    }

    func isRendering(_ key: String) -> Bool { ledger.isRendering(key) }

    private func apply(_ effects: SurfaceLedger<String, ObjectIdentifier>.Effects) {
        guard !effects.isEmpty else { return }
        for displaced in effects.displaced {
            presenters[displaced.owner]?.value?.surfaceWasDisplaced(displaced.key)
        }
        for (key, render) in effects.rendering { applyRendering(key, render) }
        for key in effects.evicted { terminals.removeValue(forKey: key)?.close() }
        presenters = presenters.filter { $0.value.value != nil }
        onPresentationChange?()
    }

    private func applyRendering(_ key: String, _ render: Bool) {
        if let entry = terminals[key] {
            entry.session.isRenderingSuspended = !render
            entry.io.setVisible(render)
            if !render {
                // Rendered off the main thread: the GPU readback used to block it.
                Task { [weak self] in
                    guard let image = await entry.session.snapshotInBackground(maxPixelSize: 480) else { return }
                    // The tab may have closed while the preview rendered.
                    guard let self, self.terminals[key] != nil else { return }
                    self.previews.insert(image, for: key)
                }
            }
        }
        if let entry = browsers[key] {
            Task { await entry.tab.setOccluded(!render) }
        }
    }

    /// The tab closed: free everything it held.
    func release(_ key: String) {
        if let owner = ledger.remove(key) { presenters[owner]?.value?.surfaceWasDisplaced(key) }
        terminals.removeValue(forKey: key)?.close()
        browsers.removeValue(forKey: key)?.close()
        browserTabs.untrack(key)
        previews.remove(key)
        onPresentationChange?()
    }

    /// Drops terminal surfaces whose tabs no longer exist.
    func prune(liveTabs: Set<String>) {
        for key in terminals.keys where !liveTabs.contains(key) { release(key) }
    }

    // MARK: Previews

    func previewImage(for key: String, maxPixelSize: CGSize) async -> CGImage? {
        if let entry = terminals[key],
           let image = await entry.session.snapshotInBackground(maxPixelSize: max(maxPixelSize.width, maxPixelSize.height)) {
            previews.insert(image, for: key)
            return image
        }
        if let entry = browsers[key], let image = try? await entry.tab.snapshot() {
            return image
        }
        return previews.image(for: key)
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

private struct WeakPresenter {
    weak var value: (any SurfacePresenter)?
}

extension TabContentCache: BrowserDevToolsObserving {
    func browserTab(_ tab: any BrowserTab, devToolsDidChange state: BrowserDevToolsState, focused: Bool) {
        guard let key = key(of: tab) else { return }
        onDevToolsChange?(key, state, focused)
    }
}
