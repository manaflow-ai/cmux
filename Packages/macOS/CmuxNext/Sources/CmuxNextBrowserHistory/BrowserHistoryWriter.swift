import AppKit
public import CmuxNextBrowser
import CmuxNextCompat
public import CmuxNextDaemon
public import Foundation
import Observation

/// Writes a browser page's back/forward entries and scroll positions to
/// its daemon tab (`frontend-browser-history-v1`), so a relaunch restores
/// them (plans/cmux-next/browser.md, "Session history across relaunch").
/// Navigations are debounced like the record write-back; scroll changes
/// fire no page event, so the shown page's position is measured when the
/// user leaves the app (a crash afterwards keeps it) and at quit.
public final class BrowserHistoryWriter {
    /// Stores a history with the tab's daemon; true when it was stored.
    public typealias Send = @MainActor (FrontendBrowserHistory) async -> Bool
    /// A page whose history the writer saves.
    public typealias Page = any BrowserTab & BrowserSessionRestoring
    /// Waits a duration (tests pass their own clock).
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// How long quit waits for the shown page to say how far it is
    /// scrolled; a page that does not answer keeps its last known position.
    static let measureBudget: Duration = .milliseconds(400)

    private(set) var recorded: FrontendBrowserHistory?
    private weak var page: Page?
    private let delay: Duration
    private let sleep: Sleep
    private let send: Send
    /// Whether the page engine's own history goes with the entries (this
    /// Mac's daemon only: it holds form data and every entry's state).
    private let keepsEngineState: Bool
    /// The page showed a password field, a file field with chosen files or a form post: its engine
    /// state is never saved again (WebKit leaves password values out of the form state it keeps,
    /// and Chromium grants a restored entry read access to the files its page state names).
    private var showedPrivateField = false
    /// Whether the last write carried engine state (`debug.browser.page_status`).
    public private(set) var savedEngineState = false
    private var observation: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    private var leaving: Task<Void, Never>?
    private var resignObserver: MainActorObservation?
    /// Where it hears that the app resigned active (tests post to their own).
    private let center: NotificationCenter

    /// Starts writing `page`'s history after each change, waiting `delay`; `recorded` is what the daemon holds.
    /// `keepsEngineState` adds the engine's own history (this Mac's daemon only).
    public init(page: Page, recorded: FrontendBrowserHistory?, keepsEngineState: Bool = false, delay: Duration,
                sleep: @escaping Sleep, center: NotificationCenter = .default, send: @escaping Send) {
        self.page = page
        self.center = center
        self.recorded = recorded
        self.keepsEngineState = keepsEngineState
        self.delay = delay
        self.sleep = sleep
        self.send = send
        observation = Task { [weak self, page] in
            for await state in ObservationStream({ HistoryKey(page.state) }) {
                self?.pageDidChange(state)
            }
        }
        resignObserver = MainActorObservation(NSApplication.didResignActiveNotification, center: center) { [weak self] in
            self?.appDidResignActive()
        }
    }

    /// The user left the app: save the shown page with its scroll position.
    /// A save still measuring covers a quick switch back and away again.
    private func appDidResignActive() {
        guard leaving == nil else { return }
        leaving = Task { [weak self] in
            await self?.flushNow()
            self?.leaving = nil
        }
    }

    /// Sends the history now with the shown page's scroll position (quit).
    public func flushNow() async {
        pending?.cancel()
        pending = nil
        guard let page else { return }
        let measured = await Self.within(Self.measureBudget, sleep: sleep) { await page.savedSession(measuringScroll: true) }
        if let measured {
            await write(measured)
        } else if let session = await page.savedSession(measuringScroll: false) {
            await write(session)
        }
    }

    /// Stops writing.
    public func cancel() {
        observation?.cancel()
        pending?.cancel()
        leaving?.cancel()
        observation = nil
        pending = nil
        leaving = nil
        resignObserver = nil
    }

    private func pageDidChange(_ key: HistoryKey) {
        pending?.cancel()
        guard key.url != nil else {
            pending = nil
            return
        }
        let delay = delay, sleep = sleep
        pending = Task { [weak self] in
            do { try await sleep(delay) } catch { return } // wakeup-allow: one `delay` per page change; the next change and cancel() cancel it
            guard let session = await self?.page?.savedSession(measuringScroll: false) else { return }
            await self?.write(session)
        }
    }

    private func write(_ session: BrowserSavedSession) async {
        guard var history = Self.history(session) else { return }
        if keepsEngineState, let page {
            // A form post (its body can name uploaded files) also keeps the page out for good: a
            // later load of the same address clears the entry's flag but not the engine's body.
            if session.entries.contains(where: \.formPost) { showedPrivateField = true }
            var probed = false  // A probe that fails to run takes no new state (the last stays).
            if !showedPrivateField {
                switch try? await page.evaluate(Self.hasPrivateField, world: .isolated, gesture: .cmux) {
                case .bool(true)?: showedPrivateField = true
                case .bool(false)?: probed = true
                default: break
                }
            }
            // Only state taken from the page the entries were saved at (the page may have moved on),
            // with every engine entry known.
            let native = (page as? any BrowserBackForwardListing)?.navigationList()?.entries.map(\.url)
            let list = native?.compactMap { $0 }
            if probed, !showedPrivateField, let list, list.count == native?.count,
               let shown = page.state.url, shown == session.entries[session.current].url,
               Self.keepsFileAccess(list + session.entries.map(\.url), shown: shown) {
                history = history.with(engineState: Self.engineState(of: page))
            } else if !probed, !showedPrivateField, let kept = recorded?.engineState,
                      recorded?.with(engineState: nil) == history {
                history = history.with(engineState: kept)
            }
        }
        savedEngineState = history.engineState != nil
        guard history != recorded else { return }
        if await send(history) { recorded = history }
    }

    /// `session` as the daemon stores it, bounded.
    static func history(_ session: BrowserSavedSession) -> FrontendBrowserHistory? {
        FrontendBrowserHistory(entries: session.entries.map { entry in
            FrontendBrowserHistory.Entry(url: entry.url.absoluteString, title: entry.title, scrollY: entry.scrollY, formPost: entry.formPost ? true : nil)
        }, index: session.current).bounded()
    }

    static let hasPrivateField = """
        !!document.querySelector('input[type=password]') || Array.prototype.some.call(\
        document.querySelectorAll('input[type=file]'), function (i) { return !!(i.files && i.files.length) })
        """

    /// Whether an engine's own history over `urls` restores without wider file access than a load
    /// of `shown` grants: no local files, or only local files in `shown`'s folder. WebKit reads a
    /// restored local entry with access to every file unless its process already reads that
    /// folder, which `BrowserHistoryStarts` grants by loading `shown` first.
    ///
    /// - Parameters:
    ///   - urls: Every entry of the history to restore.
    ///   - shown: The page the history shows.
    /// - Returns: True when restoring reads no file outside `shown`'s folder.
    public static func keepsFileAccess(_ urls: [URL], shown: URL) -> Bool {
        guard urls.contains(where: \.isFileURL) else { return true }
        guard shown.isFileURL else { return false }
        let folder = shown.standardizedFileURL.deletingLastPathComponent().path
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return urls.allSatisfy { $0.isFileURL && $0.standardizedFileURL.path.hasPrefix(prefix) }
    }

    /// Whether `history`'s entries restore without wider file access than a load of `shown`
    /// (``keepsFileAccess(_:shown:)``); false when an entry's address does not parse.
    ///
    /// - Parameters:
    ///   - history: The saved history to restore.
    ///   - shown: The page the history shows.
    /// - Returns: True when restoring reads no file outside `shown`'s folder.
    public static func keepsFileAccess(of history: FrontendBrowserHistory?, shown: URL) -> Bool {
        let entries = history?.entries.compactMap { URL(string: $0.url) } ?? []
        return entries.count == history?.entries.count && keepsFileAccess(entries, shown: shown)
    }

    /// Engine tags of state saved under the file-field and form-post rules (cx-5djb2). State
    /// saved before them ("webkit", "chromium") can name chosen files, so restore drops it.
    static let webKitTag = "webkit-2", chromiumTag = "chromium-2"

    /// The page engine's own history as the daemon stores it.
    static func engineState(of page: any BrowserTab) -> FrontendBrowserHistory.EngineState? {
        switch (page as? any BrowserHibernationSource)?.hibernationState() {
        case .webKit(let data)?: data.isEmpty ? nil : .init(engine: webKitTag, data: data.base64EncodedString())
        case .chromium(let state)?: state.isEmpty ? nil : .init(engine: chromiumTag, data: state)
        case nil: nil
        }
    }

    /// `history`'s engine state as a page restores it, when it was saved
    /// at `url` (its current entry), for a page in `engine`, by this version (`chromiumTag`), with no form post.
    public static func restoreState(_ history: FrontendBrowserHistory?, at url: URL?, engine: BrowserEngineKind) -> BrowserRestoreState? {
        guard let history, let state = history.engineState, let url, !history.entries.contains(where: { $0.formPost == true }),
              history.entries.indices.contains(history.index), history.entries[history.index].url == url.absoluteString else { return nil }
        switch (engine, state.engine) {
        case (.webkit, webKitTag): return Data(base64Encoded: state.data).map(BrowserRestoreState.webKit)
        case (.cef, chromiumTag): return .chromium(state.data)
        default: return nil
        }
    }

    /// The saved entries of `history` (nil when it has none to restore).
    public static func session(_ history: FrontendBrowserHistory) -> BrowserSavedSession? {
        let entries = history.entries.compactMap { entry in
            URL(string: entry.url).map { BrowserSavedEntry(url: $0, title: entry.title, scrollY: entry.scrollY, formPost: entry.formPost == true) }
        }
        guard entries.count == history.entries.count, entries.indices.contains(history.index) else { return nil }
        return BrowserSavedSession(entries: entries, current: history.index)
    }

    /// `work`'s result, or nil when `budget` passes first (the work then
    /// finishes unawaited).
    public static func within<T: Sendable>(_ budget: Duration, sleep: @escaping Sleep,
                                    _ work: @escaping @MainActor () async -> T?) async -> T? {
        let once = Once<T>()
        return await withCheckedContinuation { continuation in
            once.continuation = continuation
            let timer = Task { @MainActor in
                try? await sleep(budget) // wakeup-allow: the one `budget` deadline for `work`, cancelled when the work finishes first
                once.resume(nil)
            }
            Task { @MainActor in
                once.resume(await work())
                timer.cancel()
            }
        }
    }

    /// Resumes a continuation with the first answer only.
    private final class Once<T: Sendable> {
        var continuation: CheckedContinuation<T?, Never>?

        // A main-actor generic class needs a nonisolated deinit while the package targets macOS 14: the
        // isolated deinit's back-deploy path crashed swift-frontend's Release inliner
        // (EarlyPerfInliner, isCallerAndCalleeLayoutConstraintsCompatible) on its deallocating deinit.
        nonisolated deinit {}

        func resume(_ value: T?) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    /// The page changes that can change its history: a new URL or title,
    /// each load's start and end, and Back/Forward availability.
    private struct HistoryKey: Equatable, Sendable {
        var url: URL?
        var title: String?
        var isLoading: Bool
        var canGoBack: Bool
        var canGoForward: Bool

        init(_ state: BrowserTabState) {
            url = state.url
            title = state.title
            isLoading = state.isLoading
            canGoBack = state.canGoBack
            canGoForward = state.canGoForward
        }
    }
}
