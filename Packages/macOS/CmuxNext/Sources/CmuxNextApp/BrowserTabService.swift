import CmuxNextBrowser
import CmuxNextDaemon
import Foundation

/// The daemon's engine tag (the browser module has an engine protocol of the same name).
typealias BrowserEngineTag = CmuxNextDaemon.BrowserEngine

/// Daemon-owned browser tabs (`frontend-browser-tabs-v1`): creation with an
/// engine choice (`resolve`, `open`), and the debounced url/title/favicon write-back that lets
/// the daemon restore them after relaunch, with their back/forward entries
/// (`frontend-browser-history-v1`). The command closures are seams
/// for tests.
///
/// Every request goes to the daemon of the pane or tab it names
/// (`daemonForPane`, `daemonForTab`; MachineRegistry in the App): pane and
/// surface handles are per daemon, so a tab in another machine's workspace
/// is that machine's daemon's (cx-2cob). Such a tab renders and runs on this
/// Mac; its page says so once (`RemoteStrings.browserRunsOnThisMac`).
final class BrowserTabService {
    /// `new-frontend-browser-tab` in `pane` with a browser profile id (nil
    /// for an incognito tab). With `activate` false the tab stays in the
    /// background (`frontend-browser-activate-v1`); with `after` it lands
    /// right after that tab (`frontend-browser-insert-after-v1`). Returns
    /// the new surface.
    var create: @MainActor (_ daemon: DaemonService, _ pane: PaneID, _ url: String, _ engine: BrowserEngineTag, _ profile: String?,
                            _ activate: Bool, _ after: SurfaceID?) async throws -> SurfaceID
    /// The daemon that owns `pane` (the App: `MachineRegistry.daemon(forPane:)`).
    var daemonForPane: @MainActor (PaneModel) -> DaemonService
    /// The daemon that owns `tab` (the App: `MachineRegistry.daemon(forTab:)`).
    var daemonForTab: @MainActor (TabModel) -> DaemonService
    /// Every daemon, local first (tab lookups by id).
    var daemons: @MainActor () -> [DaemonService]
    /// A machine's name for the user (`MachineRegistry.machineName`).
    var machineName: @MainActor (DaemonService) -> String = { $0.machineID }
    /// Shows `text` on the page of `daemon`'s tab on `surface` when that page
    /// exists; false when it does not (TabContentCache wires it).
    var showNotice: @MainActor (DaemonService, SurfaceID, String) -> Bool = { _, _, _ in false }
    /// Returns once the store shows every change the daemon made before
    /// now (a write barrier after a create's reply), so the next link's
    /// slot sees the tab the previous link made (`BrowserTabOpeners`).
    var settled: @MainActor (DaemonService) async -> Void
    /// The browser profile a new tab in `pane` gets: the explicit one, else
    /// the workspace's, the room's or `default` (`BrowserProfileService`).
    var resolveProfile: @MainActor (_ pane: PaneModel, _ explicit: String?) -> String? = { _, explicit in explicit }
    /// A notice to show on a new tab's page once it exists (Move Tab to
    /// Browser Profile: session state stayed behind), by machine and surface.
    private var pendingNotices: [SurfaceKey: String] = [:]
    /// The same, by tab id once the store shows the tab.
    private var pendingTabNotices: [String: String] = [:]
    /// `update-frontend-browser-tab` on the tab's daemon. Returns false when the command failed.
    var update: @MainActor (DaemonService, SurfaceID, BrowserRecordUpdate) async -> Bool
    /// `tab.update` (zoom, back/forward) on the tab's public id, on its
    /// daemon. Returns false when the command failed.
    var updateState: @MainActor (DaemonService, ResourceID, BrowserRecordUpdate) async -> Bool
    /// Whether the tab's daemon keeps zoom and history (state resources).
    var keepsState: @MainActor (TabModel) -> Bool
    /// `set-frontend-browser-history`. Returns false when the command failed.
    var storeHistory: @MainActor (DaemonService, SurfaceID, FrontendBrowserHistory) async -> Bool
    /// `get-frontend-browser-history`; nil when there is none or the daemon
    /// does not store it.
    var fetchHistory: @MainActor (DaemonService, SurfaceID) async -> FrontendBrowserHistory?
    /// Whether `daemon` serves `frontend-browser-tabs-v1`.
    var serves: @MainActor (DaemonService) -> Bool = { $0.supports(DaemonCapabilities.shared.frontendBrowserTabs) }
    /// Why Chromium cannot open a tab now; nil when it can (or may still
    /// start).
    var cefUnavailable: @MainActor () -> CEFUnavailableReason?
    /// `browser.defaultEngine`, live.
    let preference = BrowserEnginePreference()
    /// Chromium-to-WebKit fallbacks and the one-time notice.
    let fallbacks = ChromiumFallbackLog()
    /// The current model of the tab with durable id `id` (a moved tab gets
    /// a new TabModel in its destination pane), nil when it closed.
    var tabModel: @MainActor (_ id: String) -> TabModel?
    var writeBackDelay: Duration = .milliseconds(500)
    // wakeup-allow: one-shot debounce of browser record write-back (injected for tests)
    var sleep: BrowserRecordWriter.Sleep = { try await ContinuousClock().sleep(for: $0) }
    private var writers: [String: BrowserRecordWriter] = [:]
    private var historyWriters: [String: BrowserHistoryWriter] = [:]
    /// Stored-history reads in flight, by tab id (cancelled with the page).
    private var historyFetches: [String: Task<Void, Never>] = [:]
    /// True for a pane of an incognito window (the App sets it).
    var isIncognitoPane: @MainActor (PaneModel) -> Bool = { _ in false }
    /// True for a tab of an incognito window, by tab id (the App sets it).
    var isIncognitoTab: @MainActor (String) -> Bool = { _ in false }
    /// Start URLs of incognito tabs, by surface, in memory only.
    private var incognitoURLs: [SurfaceKey: String] = [:]
    /// Surfaces created in this process (`open`): pages the user asked for
    /// now, as opposed to tabs restored from the daemon.
    private var openedSurfaces: Set<SurfaceKey> = []

    /// A surface on one machine (handles are per daemon).
    struct SurfaceKey: Hashable {
        let machine: String
        let surface: SurfaceID
    }

    init(daemon local: DaemonService, cef: CEFEngine) {
        // The service lives in the cache, which the App owns beside the local daemon (no cycle).
        daemonForPane = { [local] _ in local }
        daemonForTab = { [local] _ in local }
        daemons = { [local] in [local] }
        create = { daemon, pane, url, engine, profile, activate, after in
            // An older daemon without the capability would ignore the field: send it only when served.
            let background = !activate && daemon.supports(DaemonCapabilities.shared.frontendBrowserActivate)
            let slot = daemon.supports(DaemonCapabilities.shared.frontendBrowserInsertAfter) ? after : nil
            // Through the funnel: the action scope waits for the tab's echo
            // before it maps `created` to public ids.
            return try await daemon.perform(NewFrontendBrowserTabRequest.command) { connection in
                try await connection.newFrontendBrowserTab(url: url, engine: engine, in: pane, profileID: profile,
                                                           activate: background ? false : nil, after: slot).surface
            }
        }
        settled = { daemon in
            guard let connection = daemon.connection else { return }
            await daemon.store.applied(through: await connection.eventSequence())
        }
        update = { daemon, surface, update in
            await daemon.run("update-frontend-browser-tab") { connection in
                _ = try await connection.updateFrontendBrowserTab(surface, url: update.url, title: update.title, faviconURL: update.favicon)
            }
        }
        updateState = { daemon, tab, update in
            await daemon.run("tab.update") { connection in
                try await connection.state.updateTabRecord(tab, zoom: update.zoom, back: update.back, forward: update.forward)
            }
        }
        keepsState = { _ in false }
        storeHistory = { daemon, surface, history in
            guard daemon.supports(DaemonCapabilities.shared.frontendBrowserHistory) else { return false }
            return await daemon.run(SetFrontendBrowserHistoryRequest.command) { connection in
                _ = try await connection.request(SetFrontendBrowserHistoryRequest(surface: surface, history: history))
            }
        }
        fetchHistory = { daemon, surface in
            guard daemon.supports(DaemonCapabilities.shared.frontendBrowserHistory), let connection = daemon.connection else { return nil }
            return try? await connection.request(GetFrontendBrowserHistoryRequest(surface: surface)).history
        }
        tabModel = { _ in nil }
        cefUnavailable = { [weak cef] in
            // `?? .notBundled` on the optional chain would turn "available" (nil) into notBundled.
            guard let cef else { return .notBundled }
            return cef.unavailableReason
        }
        keepsState = { [weak self] tab in self?.daemonForTab(tab).store.servesStateResources ?? false }
        tabModel = { [weak self] id in
            for daemon in self?.daemons() ?? [] {
                if let tab = daemon.store.workspaces.lazy.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first(where: { $0.id == id }) {
                    return tab
                }
            }
            return nil
        }
    }

    /// The daemon that owns `tab`.
    func daemon(for tab: TabModel) -> DaemonService { daemonForTab(tab) }

    private func key(_ daemon: DaemonService, _ surface: SurfaceID) -> SurfaceKey {
        SurfaceKey(machine: daemon.machineID, surface: surface)
    }

    /// Whether the daemon of `pane` serves app-rendered browser tabs.
    func isAvailable(in pane: PaneModel) -> Bool { serves(daemonForPane(pane)) }

    /// Whether `daemon` serves app-rendered browser tabs.
    func isAvailable(on daemon: DaemonService) -> Bool { serves(daemon) }

    /// Why no browser tab can open in `pane` now, for the person (never a
    /// silent no-op): its machine is not connected. Nil otherwise; a
    /// connected machine whose cmux-tui lacks daemon browser tabs gets the
    /// session-local fallback where the caller has one
    /// (`PaneBrowserTabOpener.machineRoute`), else the caller's capability refusal.
    func refusal(in pane: PaneModel) -> String? {
        let daemon = daemonForPane(pane)
        guard !daemon.isLocal, daemon.connection == nil else { return nil }
        return RemoteStrings.browserMachineNotConnected(machineName(daemon))
    }

    /// The notice for the page of session-local tab `key` (no daemon record).
    func setNotice(_ text: String, forKey key: String) { pendingTabNotices[key] = text }

    /// The pending notice of the page with tab key `key`, once.
    func takeNotice(forKey key: String) -> String? { pendingTabNotices.removeValue(forKey: key) }

    /// Whether `tab` was created in this process (`open`), not restored.
    func wasOpenedHere(_ tab: TabModel) -> Bool { openedSurfaces.contains(key(daemonForTab(tab), tab.surface)) }

    /// The daemon record URL of an incognito tab.
    static let incognitoPlaceholderURL = "about:blank"

    /// The URL a new page of `tab` starts on: an incognito tab's from app
    /// memory, else its record's.
    func startURL(for tab: TabModel) -> String? { incognitoURLs[key(daemonForTab(tab), tab.surface)] ?? tab.url }

    /// Forgets incognito start URLs (the incognito session ended).
    func forgetIncognitoURLs() { incognitoURLs.removeAll() }

    func cefAvailable() -> Bool { cefUnavailable() == nil }

    /// Why Chromium cannot open a tab (localized), nil when it can.
    func cefUnavailableReason() -> String? {
        cefUnavailable().map(Self.message)
    }

    static func message(_ reason: CEFUnavailableReason) -> String {
        reason.detail ?? RefusalStrings.chromiumUnavailable
    }

    /// The engine for a new tab (`BrowserEngineResolver`): an explicit
    /// engine, else an inherited one, else `browser.defaultEngine`, with the
    /// WebKit fallback for the last two.
    func resolve(requested: String?, inherited: String? = nil) -> BrowserEngineResolver.Outcome {
        BrowserEngineResolver.resolve(requested: requested, inherited: inherited,
                                      defaultEngine: preference.defaultEngine, cefUnavailable: cefUnavailable())
    }

    /// Creates the daemon record for `choice` in `pane` and records a
    /// fallback against the new surface (its page shows the notice). A tab
    /// of an incognito window (`incognito`, else `isIncognitoPane`) gets an
    /// opaque placeholder record; its URL stays in app memory
    /// (`startURL(for:)`), never in the daemon's database.
    /// The tab's browser profile is fixed here (`profile` when it names a
    /// known one, else the cascade) and stored on its record; an incognito
    /// tab stores none (its window's session is its store). `after` is the
    /// tab the new one goes right after (a link's opener or its last child).
    /// A tab opened in another machine's pane renders and runs on this Mac:
    /// its page says so once, unless the caller has its own notice.
    func open(_ choice: BrowserEngineChoice, in pane: PaneModel, url: String, incognito: Bool? = nil, profile explicit: String? = nil,
              notice: String? = nil, activate: Bool = true, after: SurfaceID? = nil) async throws -> SurfaceID {
        let daemon = daemonForPane(pane)
        let offTheRecord = incognito ?? isIncognitoPane(pane)
        let profile = offTheRecord ? nil : resolveProfile(pane, explicit)
        // A machine browser record runs there: no "runs on this Mac" notice.
        let runsHere = !daemon.isLocal && !MachineBrowserRecord.matches(URL(string: url))
        let shown = notice ?? (runsHere ? RemoteStrings.browserRunsOnThisMac(machineName(daemon)) : nil)
        return try await open(choice, in: pane.handle, on: daemon, url: url, offTheRecord: offTheRecord, profile: profile,
                              notice: shown, activate: activate, after: after)
    }

    /// `open` for a pane of `daemon` that the caller just created (the pane
    /// model may not be in the store yet). The profile is the explicit one
    /// or `default`.
    func open(_ choice: BrowserEngineChoice, in pane: PaneID, on daemon: DaemonService, url: String, incognito: Bool = false,
              profile explicit: String? = nil) async throws -> SurfaceID {
        let model = daemon.store.pane(pane)
        let profile = incognito ? nil : model.map { resolveProfile($0, explicit) } ?? explicit
        return try await open(choice, in: pane, on: daemon, url: url, offTheRecord: incognito, profile: profile, notice: nil,
                              activate: true, after: nil)
    }

    private func open(_ choice: BrowserEngineChoice, in pane: PaneID, on daemon: DaemonService, url: String, offTheRecord: Bool,
                      profile: String?, notice: String?, activate: Bool, after: SurfaceID?) async throws -> SurfaceID {
        let surface = try await create(daemon, pane, offTheRecord ? Self.incognitoPlaceholderURL : url, choice.engine, profile, activate, after)
        let key = key(daemon, surface)
        if offTheRecord { incognitoURLs[key] = url }
        // The tab's page may exist already (the store echoed the tab before
        // the reply): it shows the notice now; else its page takes it.
        if let notice, !showNotice(daemon, surface, notice) {
            // By tab id when the store already has the tab (ids are unique
            // across machines, and a page looks its notice up by its tab).
            if let tab = daemon.store.tab(surface: surface) { pendingTabNotices[tab.id] = notice } else { pendingNotices[key] = notice }
        }
        openedSurfaces.insert(key)
        if let reason = choice.fallback {
            fallbacks.record(reason, source: choice.inherited ? .recordedTab : .newTab, machine: daemon.machineID, surface: surface)
        }
        return surface
    }

    /// The notice to show on the page of `tab`, once.
    func takeNotice(for tab: TabModel) -> String? {
        pendingTabNotices.removeValue(forKey: tab.id) ?? pendingNotices.removeValue(forKey: key(daemonForTab(tab), tab.surface))
    }

    /// Starts writing `page` back to the daemon record of `tab` (keyed by
    /// tab id; one writer per live page).
    /// An incognito tab is never written back: its page's URL, title and
    /// favicon stay in memory (the tab strip reads the live page).
    /// A page restores the zoom its record keeps.
    func track(_ page: any BrowserTab, for tab: TabModel) {
        guard tab.isFrontendOwned, writers[tab.id] == nil, !isIncognitoTab(tab.id) else { return }
        let update = update, updateState = updateState, id = tab.id, daemonForTab = daemonForTab
        let keeps = keepsState(tab)
        if keeps, let zoom = tab.zoom, abs(page.state.zoom - zoom) > 0.001 { page.setZoom(zoom) }
        // The surface is looked up by tab id at send time. A moved tab (a
        // split, another window) keeps its record, but the store gives it a
        // new TabModel in the destination pane, so the writer must not hold
        // the original one.
        let writer = BrowserRecordWriter(
            tab: page, recorded: BrowserRecord(tab: tab), tracksState: keeps,
            daemonRecord: { [weak self] in self?.tabModel(id).map(BrowserRecord.init(tab:)) },
            delay: writeBackDelay, sleep: sleep
        ) { [weak self] fields in
            guard let tab = self?.tabModel(id) else { return false }
            let daemon = daemonForTab(tab)
            if fields.hasRecordFields, !(await update(daemon, tab.surface, fields)) { return false }
            guard fields.hasStateFields else { return true }
            guard let resource = tab.resourceID else { return false }
            return await updateState(daemon, resource, fields)
        }
        writers[id] = writer
        trackHistory(page, id: id, daemon: daemonForTab(tab), surface: tab.surface, recordURL: tab.url, while: writer)
    }

    /// Restores `page`'s back/forward entries from the daemon when its tab
    /// reopens at the page they were saved on, then writes them back as
    /// they change (`BrowserHistoryWriter`).
    private func trackHistory(_ page: any BrowserTab, id: String, daemon: DaemonService, surface: SurfaceID, recordURL: String?,
                              while record: BrowserRecordWriter) {
        guard let restoring = page as? any BrowserTab & BrowserSessionRestoring else { return }
        let fetchHistory = fetchHistory, storeHistory = storeHistory, daemonForTab = daemonForTab
        historyFetches[id]?.cancel()
        historyFetches[id] = Task { [weak self, weak record] in
            let saved = await fetchHistory(daemon, surface)
            // A cancelled read's handle may already be a newer one's.
            guard !Task.isCancelled else { return }
            self?.historyFetches[id] = nil
            // The page may have been released or replaced while the daemon
            // answered: its record writer is then gone.
            guard let self, let record, self.writers[id] === record, self.historyWriters[id] == nil else { return }
            // The saved page is the one the tab reopened at, and the user
            // has not gone elsewhere while the daemon answered.
            if let saved, let session = BrowserHistoryWriter.session(saved),
               session.entries[session.current].url.absoluteString == recordURL,
               restoring.state.url.map({ $0.absoluteString == recordURL }) ?? true {
                restoring.restoreSession(session.entries, current: session.current)
            }
            self.historyWriters[id] = BrowserHistoryWriter(page: restoring, recorded: saved, delay: self.writeBackDelay,
                                                           sleep: self.sleep) { [weak self] history in
                guard let tab = self?.tabModel(id) else { return false }
                return await storeHistory(daemonForTab(tab), tab.surface, history)
            }
        }
    }

    /// `track` for the tab's current model, looked up by id: for a page
    /// that finished starting after the tab moved (its old TabModel is gone).
    func track(_ page: any BrowserTab, tabID: String) {
        if let tab = tabModel(tabID) { track(page, for: tab) }
    }

    /// The page was released: stop writing.
    func untrack(_ key: String) {
        writers.removeValue(forKey: key)?.cancel()
        historyWriters.removeValue(forKey: key)?.cancel()
        historyFetches.removeValue(forKey: key)?.cancel()
    }

    func isTracking(_ key: String) -> Bool { writers[key] != nil }

    /// Sends every page change still waiting out the write-back delay, so
    /// the record reopened at relaunch is the page the user last saw.
    func flushRecords() async {
        for writer in writers.values { await writer.flushNow() }
        // Each page is asked for its scroll position at once, not in turn.
        // task-owner: every flush is awaited before quit goes on.
        let flushes = historyWriters.values.map { writer in Task { await writer.flushNow() } }
        for flush in flushes { await flush.value }
    }
}
