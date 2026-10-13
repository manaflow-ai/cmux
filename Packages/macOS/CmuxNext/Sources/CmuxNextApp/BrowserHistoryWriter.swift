import AppKit
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDaemon
import Foundation
import Observation

/// Writes a browser page's back/forward entries and scroll positions to
/// its daemon tab (`frontend-browser-history-v1`), so a relaunch restores
/// them (plans/cmux-next/browser.md, "Session history across relaunch").
/// Navigations are debounced like the record write-back; scroll changes
/// fire no page event, so the shown page's position is measured when the
/// user leaves the app (a crash afterwards keeps it) and at quit.
final class BrowserHistoryWriter {
    typealias Send = @MainActor (FrontendBrowserHistory) async -> Bool
    typealias Page = any BrowserTab & BrowserSessionRestoring

    /// How long quit waits for the shown page to say how far it is
    /// scrolled; a page that does not answer keeps its last known position.
    static let measureBudget: Duration = .milliseconds(400)

    private(set) var recorded: FrontendBrowserHistory?
    private weak var page: Page?
    private let delay: Duration
    private let sleep: BrowserRecordWriter.Sleep
    private let send: Send
    /// Whether the page engine's own history goes with the entries (this
    /// Mac's daemon only: it holds form data and every entry's state).
    private let keepsEngineState: Bool
    /// The page showed a password field: its engine state is never saved again (WebKit leaves
    /// password values out of the form state it keeps; this keeps such pages out entirely).
    private var showedPasswordField = false
    /// Whether the last write carried engine state (`debug.browser.page_status`).
    private(set) var savedEngineState = false
    private var observation: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    private var leaving: Task<Void, Never>?
    private var resignObserver: (any NSObjectProtocol)?

    init(page: Page, recorded: FrontendBrowserHistory?, keepsEngineState: Bool = false, delay: Duration,
         sleep: @escaping BrowserRecordWriter.Sleep, send: @escaping Send) {
        self.page = page
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
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appDidResignActive() } // main-proof: observer on queue: .main
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
    func flushNow() async {
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

    func cancel() {
        observation?.cancel()
        pending?.cancel()
        leaving?.cancel()
        observation = nil
        pending = nil
        leaving = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
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
            do { try await sleep(delay) } catch { return }
            guard let session = await self?.page?.savedSession(measuringScroll: false) else { return }
            await self?.write(session)
        }
    }

    private func write(_ session: BrowserSavedSession) async {
        guard var history = Self.history(session) else { return }
        if keepsEngineState, let page {
            if !showedPasswordField, case .bool(true)? = try? await page.evaluate(Self.hasPasswordField, world: .isolated) {
                showedPasswordField = true
            }
            // Only state taken from the page the entries were saved at (the page may have moved on).
            let list = (page as? any BrowserBackForwardListing)?.navigationList()?.entries.compactMap(\.url) ?? []
            if !showedPasswordField, let shown = page.state.url, shown == session.entries[session.current].url,
               Self.keepsFileAccess(list + session.entries.map(\.url), shown: shown) {
                history = history.with(engineState: Self.engineState(of: page))
            }
        }
        savedEngineState = history.engineState != nil
        guard history != recorded else { return }
        if await send(history) { recorded = history }
    }

    /// `session` as the daemon stores it, bounded.
    static func history(_ session: BrowserSavedSession) -> FrontendBrowserHistory? {
        FrontendBrowserHistory(entries: session.entries.map { entry in
            FrontendBrowserHistory.Entry(url: entry.url.absoluteString, title: entry.title, scrollY: entry.scrollY)
        }, index: session.current).bounded()
    }

    static let hasPasswordField = "!!document.querySelector('input[type=password]')"

    /// Whether WebKit's own history over `urls` restores without wider file access than a load
    /// of `shown` grants: no local files, or only local files in `shown`'s folder. WebKit reads a
    /// restored local entry with access to every file unless its process already reads that
    /// folder, which `BrowserHistoryStarts` grants by loading `shown` first.
    static func keepsFileAccess(_ urls: [URL], shown: URL) -> Bool {
        guard urls.contains(where: \.isFileURL) else { return true }
        guard shown.isFileURL else { return false }
        let folder = shown.standardizedFileURL.deletingLastPathComponent().path
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return urls.allSatisfy { $0.isFileURL && $0.standardizedFileURL.path.hasPrefix(prefix) }
    }

    /// The page engine's own history as the daemon stores it.
    static func engineState(of page: any BrowserTab) -> FrontendBrowserHistory.EngineState? {
        switch (page as? any BrowserHibernationSource)?.hibernationState() {
        case .webKit(let data)?: data.isEmpty ? nil : .init(engine: "webkit", data: data.base64EncodedString())
        case .chromium(let state)?: state.isEmpty ? nil : .init(engine: "chromium", data: state)
        case nil: nil
        }
    }

    /// `history`'s engine state as a page restores it, when it was saved
    /// at `url` (its current entry), for a page in `engine`.
    static func restoreState(_ history: FrontendBrowserHistory?, at url: URL?, engine: BrowserEngineKind) -> BrowserRestoreState? {
        guard let history, let state = history.engineState, let url,
              history.entries.indices.contains(history.index), history.entries[history.index].url == url.absoluteString else { return nil }
        switch (engine, state.engine) {
        case (.webkit, "webkit"): return Data(base64Encoded: state.data).map(BrowserRestoreState.webKit)
        case (.cef, "chromium"): return .chromium(state.data)
        default: return nil
        }
    }

    /// The saved entries of `history` (nil when it has none to restore).
    static func session(_ history: FrontendBrowserHistory) -> BrowserSavedSession? {
        let entries = history.entries.compactMap { entry in
            URL(string: entry.url).map { BrowserSavedEntry(url: $0, title: entry.title, scrollY: entry.scrollY) }
        }
        guard entries.count == history.entries.count, entries.indices.contains(history.index) else { return nil }
        return BrowserSavedSession(entries: entries, current: history.index)
    }

    /// `work`'s result, or nil when `budget` passes first (the work then
    /// finishes unawaited).
    static func within<T: Sendable>(_ budget: Duration, sleep: @escaping BrowserRecordWriter.Sleep,
                                    _ work: @escaping @MainActor () async -> T?) async -> T? {
        let once = Once<T>()
        return await withCheckedContinuation { continuation in
            once.continuation = continuation
            let timer = Task { @MainActor in
                try? await sleep(budget)
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
