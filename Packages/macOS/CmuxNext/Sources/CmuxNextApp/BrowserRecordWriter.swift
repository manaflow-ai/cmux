import CmuxNextBrowser
import CmuxNextDaemon
import Foundation
import Observation

/// The url, title, and favicon the daemon records for a frontend browser
/// tab (`frontend-browser-tabs-v1`). The engine is the live source; the
/// record is what survives relaunch.
struct BrowserRecord: Equatable, Sendable {
    var url: String?
    var title: String?
    var faviconURL: String?

    init(url: String? = nil, title: String? = nil, faviconURL: String? = nil) {
        self.url = url
        self.title = title
        self.faviconURL = faviconURL
    }

    init(tab: TabModel) {
        self.init(url: tab.url, title: tab.title.isEmpty ? nil : tab.title, faviconURL: tab.faviconURL)
    }

    /// The fields `update-frontend-browser-tab` should send to move this
    /// record to `page`, or nil when nothing changed. A page without a URL
    /// (nothing committed yet) or title keeps the recorded value; the favicon
    /// is cleared only once a load finished without one.
    func update(toward page: BrowserTabState) -> BrowserRecordUpdate? {
        let pageURL = page.url?.absoluteString
        let url = pageURL.flatMap { $0 == self.url ? nil : $0 }
        let title = page.title.flatMap { $0.isEmpty || $0 == self.title ? nil : $0 }
        let favicon: FieldUpdate<String>
        if let icon = page.faviconURL?.absoluteString {
            favicon = icon == faviconURL ? .unchanged : .set(icon)
        } else if faviconURL != nil, case .finished = page.phase {
            favicon = .clear
        } else {
            favicon = .unchanged
        }
        guard url != nil || title != nil || favicon != .unchanged else { return nil }
        return BrowserRecordUpdate(url: url, title: title, favicon: favicon)
    }

    func applying(_ update: BrowserRecordUpdate) -> BrowserRecord {
        var next = self
        if let url = update.url { next.url = url }
        if let title = update.title { next.title = title }
        switch update.favicon {
        case .unchanged: break
        case .clear: next.faviconURL = nil
        case .set(let value): next.faviconURL = value
        }
        return next
    }
}

/// One `update-frontend-browser-tab` call's fields.
struct BrowserRecordUpdate: Equatable, Sendable {
    var url: String?
    var title: String?
    var favicon: FieldUpdate<String>
}

/// Writes a live page's url/title/favicon back to its daemon tab record,
/// debounced: page changes restart the delay, so a burst of navigation
/// events sends one command after it settles. A failed send keeps the old
/// record, so the next change retries the full difference.
final class BrowserRecordWriter {
    typealias Send = @MainActor (BrowserRecordUpdate) async -> Bool
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private(set) var recorded: BrowserRecord
    private let delay: Duration
    private let sleep: Sleep
    private let send: Send
    private var observation: Task<Void, Never>?
    private var pending: Task<Void, Never>?

    init(tab: any BrowserTab, recorded: BrowserRecord, delay: Duration, sleep: @escaping Sleep, send: @escaping Send) {
        self.recorded = recorded
        self.delay = delay
        self.sleep = sleep
        self.send = send
        observation = Task { [weak self, tab] in
            for await state in Observations({ tab.state }) {
                self?.pageDidChange(state)
            }
        }
    }

    func cancel() {
        observation?.cancel()
        pending?.cancel()
        observation = nil
        pending = nil
    }

    private func pageDidChange(_ state: BrowserTabState) {
        pending?.cancel()
        guard recorded.update(toward: state) != nil else {
            pending = nil
            return
        }
        let delay = delay, sleep = sleep
        pending = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            await self?.flush(state)
        }
    }

    private func flush(_ state: BrowserTabState) async {
        guard let update = recorded.update(toward: state) else { return }
        let base = recorded
        guard await send(update) else { return }
        if recorded == base { recorded = base.applying(update) }
    }
}
