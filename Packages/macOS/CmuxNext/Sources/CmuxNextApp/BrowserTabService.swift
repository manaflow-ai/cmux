import CmuxNextBrowser
import CmuxNextDaemon
import Foundation

/// The daemon's engine tag (the browser module has an engine protocol of the same name).
typealias BrowserEngineTag = CmuxNextDaemon.BrowserEngine

/// Daemon-owned browser tabs (`frontend-browser-tabs-v1`): creation with an
/// engine choice (`resolve`, `open`), and the debounced url/title/favicon write-back that lets
/// the daemon restore them after relaunch. The command closures are seams
/// for tests.
final class BrowserTabService {
    /// `new-frontend-browser-tab` in `pane` with a browser profile id (nil
    /// for an incognito tab). Returns the new surface.
    var create: @MainActor (_ pane: PaneID, _ url: String, _ engine: BrowserEngineTag, _ profile: String?) async throws -> SurfaceID
    /// The browser profile a new tab in `pane` gets: the explicit one, else
    /// the workspace's, the room's or `default` (`BrowserProfileService`).
    var resolveProfile: @MainActor (_ pane: PaneID, _ explicit: String?) -> String? = { _, explicit in explicit }
    /// A notice to show on a new tab's page once it exists (Move Tab to
    /// Browser Profile: session state stayed behind), by surface.
    private var pendingNotices: [SurfaceID: String] = [:]
    /// `update-frontend-browser-tab`. Returns false when the command failed.
    var update: @MainActor (SurfaceID, BrowserRecordUpdate) async -> Bool
    /// Whether the daemon serves `frontend-browser-tabs-v1`.
    var isAvailable: @MainActor () -> Bool
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
    /// True for a pane of an incognito window (the App sets it).
    var isIncognitoPane: @MainActor (PaneID) -> Bool = { _ in false }
    /// True for a tab of an incognito window, by tab id (the App sets it).
    var isIncognitoTab: @MainActor (String) -> Bool = { _ in false }
    /// Start URLs of incognito tabs, by surface, in memory only.
    private var incognitoURLs: [SurfaceID: String] = [:]
    /// Surfaces created in this process (`open`): pages the user asked for
    /// now, as opposed to tabs restored from the daemon.
    private(set) var openedSurfaces: Set<SurfaceID> = []

    init(daemon: DaemonService, cef: CEFEngine) {
        create = { [weak daemon] pane, url, engine, profile in
            guard let connection = daemon?.connection else { throw DaemonError.notConnected }
            return try await connection.newFrontendBrowserTab(url: url, engine: engine, in: pane, profileID: profile).surface
        }
        update = { [weak daemon] surface, update in
            await daemon?.run("update-frontend-browser-tab") { connection in
                _ = try await connection.updateFrontendBrowserTab(surface, url: update.url, title: update.title, faviconURL: update.favicon)
            } ?? false
        }
        tabModel = { [weak daemon] id in
            daemon?.store.workspaces.lazy.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { $0.id == id }
        }
        isAvailable = { [weak daemon] in daemon?.supports(DaemonCapabilities.frontendBrowserTabs) ?? false }
        cefUnavailable = { [weak cef] in
            // `?? .notBundled` on the optional chain would turn "available" (nil) into notBundled.
            guard let cef else { return .notBundled }
            return cef.unavailableReason
        }
    }

    /// The daemon record URL of an incognito tab.
    static let incognitoPlaceholderURL = "about:blank"

    /// The URL a new page of `tab` starts on: an incognito tab's from app
    /// memory, else its record's.
    func startURL(for tab: TabModel) -> String? { incognitoURLs[tab.surface] ?? tab.url }

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
    /// tab stores none (its window's session is its store).
    func open(_ choice: BrowserEngineChoice, in pane: PaneID, url: String, incognito: Bool? = nil, profile explicit: String? = nil,
              notice: String? = nil) async throws -> SurfaceID {
        let offTheRecord = incognito ?? isIncognitoPane(pane)
        let profile = offTheRecord ? nil : resolveProfile(pane, explicit)
        let surface = try await create(pane, offTheRecord ? Self.incognitoPlaceholderURL : url, choice.engine, profile)
        if offTheRecord { incognitoURLs[surface] = url }
        if let notice { pendingNotices[surface] = notice }
        openedSurfaces.insert(surface)
        if let reason = choice.fallback {
            fallbacks.record(reason, source: choice.inherited ? .recordedTab : .newTab, surface: surface)
        }
        return surface
    }

    /// The notice to show on the page of the tab on `surface`, once.
    func takeNotice(for surface: SurfaceID) -> String? { pendingNotices.removeValue(forKey: surface) }

    /// Starts writing `page` back to the daemon record of `tab` (keyed by
    /// tab id; one writer per live page).
    /// An incognito tab is never written back: its page's URL, title and
    /// favicon stay in memory (the tab strip reads the live page).
    func track(_ page: any BrowserTab, for tab: TabModel) {
        guard tab.isFrontendOwned, writers[tab.id] == nil, !isIncognitoTab(tab.id) else { return }
        let update = update, id = tab.id
        // The surface is looked up by tab id at send time. A moved tab (a
        // split, another window) keeps its record, but the store gives it a
        // new TabModel in the destination pane, so the writer must not hold
        // the original one.
        writers[id] = BrowserRecordWriter(tab: page, recorded: BrowserRecord(tab: tab), delay: writeBackDelay, sleep: sleep) { [weak self] fields in
            guard let surface = self?.tabModel(id)?.surface else { return false }
            return await update(surface, fields)
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
    }

    func isTracking(_ key: String) -> Bool { writers[key] != nil }
}
