import CmuxNextBrowser
import CmuxNextDaemon
import Foundation
import Observation

/// Writes a Chromium page's back/forward entries and scroll positions to
/// its daemon tab (`frontend-browser-history-v1`), so a relaunch restores
/// them (plans/cmux-next/browser.md, "Session history across relaunch").
/// Navigations are debounced like the record write-back; scroll changes
/// fire no page event, so the shown page's position is measured at quit.
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
    private var observation: Task<Void, Never>?
    private var pending: Task<Void, Never>?

    init(page: Page, recorded: FrontendBrowserHistory?, delay: Duration, sleep: @escaping BrowserRecordWriter.Sleep, send: @escaping Send) {
        self.page = page
        self.recorded = recorded
        self.delay = delay
        self.sleep = sleep
        self.send = send
        observation = Task { [weak self, page] in
            for await state in Observations({ HistoryKey(page.state) }) {
                self?.pageDidChange(state)
            }
        }
    }

    /// Sends the history now with the shown page's scroll position (quit).
    func flushNow() async {
        pending?.cancel()
        pending = nil
        guard let page else { return }
        let measured = await Self.within(Self.measureBudget, sleep: sleep) { await page.savedSession(measuringScroll: true) }
        guard let session = measured ?? (await page.savedSession(measuringScroll: false)) else { return }
        await write(session)
    }

    func cancel() {
        observation?.cancel()
        pending?.cancel()
        observation = nil
        pending = nil
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
        guard let history = Self.history(session), history != recorded else { return }
        if await send(history) { recorded = history }
    }

    /// `session` as the daemon stores it, bounded.
    static func history(_ session: BrowserSavedSession) -> FrontendBrowserHistory? {
        FrontendBrowserHistory(entries: session.entries.map { entry in
            FrontendBrowserHistory.Entry(url: entry.url.absoluteString, title: entry.title, scrollY: entry.scrollY)
        }, index: session.current).bounded()
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
