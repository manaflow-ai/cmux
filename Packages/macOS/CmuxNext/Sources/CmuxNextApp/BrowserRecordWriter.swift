import CmuxNextBrowser
import CmuxNextDaemon
import Foundation
import Observation

/// The url, title, and favicon the daemon records for a frontend browser
/// tab (`frontend-browser-tabs-v1`), and on daemons with state resources
/// its zoom and back/forward lists (`tab.update`). The engine is the live
/// source; the record is what survives relaunch.
struct BrowserRecord: Equatable, Sendable {
    var url: String?
    var title: String?
    var faviconURL: String?
    /// Page zoom; nil = 100 %.
    var zoom: Double?
    var back: [String] = []
    var forward: [String] = []

    init(url: String? = nil, title: String? = nil, faviconURL: String? = nil, zoom: Double? = nil, back: [String] = [],
         forward: [String] = []) {
        self.url = url
        self.title = title
        self.faviconURL = faviconURL
        self.zoom = zoom
        self.back = back
        self.forward = forward
    }

    init(tab: TabModel) {
        self.init(url: tab.url, title: tab.title.isEmpty ? nil : tab.title, faviconURL: tab.faviconURL, zoom: tab.zoom,
                  back: tab.backURLs, forward: tab.forwardURLs)
    }

    /// The fields to send to move this record to `page`, or nil when nothing
    /// changed. A page without a URL (nothing committed yet) or title keeps
    /// the recorded value; the favicon is cleared only once a load finished
    /// without one. Zoom and history are compared only with `state` (the
    /// daemon keeps them), history only when the engine reports it.
    func update(toward page: BrowserTabState, state: Bool = false) -> BrowserRecordUpdate? {
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
        var update = BrowserRecordUpdate(url: url, title: title, favicon: favicon)
        if state {
            let zoom = abs(page.zoom - 1) < 0.001 ? nil : page.zoom
            if zoom != self.zoom { update.zoom = zoom.map(FieldUpdate.set) ?? .clear }
            if let back = page.backURLs, back != self.back { update.back = back }
            if let forward = page.forwardURLs, forward != self.forward { update.forward = forward }
        }
        return update.isEmpty ? nil : update
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
        switch update.zoom {
        case .unchanged: break
        case .clear: next.zoom = nil
        case .set(let value): next.zoom = value
        }
        if let back = update.back { next.back = back }
        if let forward = update.forward { next.forward = forward }
        return next
    }
}

/// One write-back: `update-frontend-browser-tab` fields (url, title,
/// favicon) and `tab.update` fields (zoom, back, forward).
struct BrowserRecordUpdate: Equatable, Sendable {
    var url: String?
    var title: String?
    var favicon: FieldUpdate<String>
    var zoom: FieldUpdate<Double> = .unchanged
    var back: [String]?
    var forward: [String]?

    init(url: String?, title: String?, favicon: FieldUpdate<String>, zoom: FieldUpdate<Double> = .unchanged,
         back: [String]? = nil, forward: [String]? = nil) {
        self.url = url
        self.title = title
        self.favicon = favicon
        self.zoom = zoom
        self.back = back
        self.forward = forward
    }

    /// Fields `update-frontend-browser-tab` carries.
    var hasRecordFields: Bool { url != nil || title != nil || favicon != .unchanged }
    /// Fields `tab.update` carries.
    var hasStateFields: Bool { zoom != .unchanged || back != nil || forward != nil }
    var isEmpty: Bool { !hasRecordFields && !hasStateFields }
}

/// Writes a live page's record back to its daemon tab, debounced: page
/// changes restart the delay, so a burst of navigation events sends one
/// command after it settles. A failed send keeps the old record, so the
/// next change retries the full difference. The copy follows the daemon:
/// each change of the tab's daemon record (`daemonRecord`, another client,
/// a restore, this writer's own echo) re-bases it, so a difference is always
/// computed against what the daemon holds.
final class BrowserRecordWriter {
    typealias Send = @MainActor (BrowserRecordUpdate) async -> Bool
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private(set) var recorded: BrowserRecord
    private let delay: Duration
    private let sleep: Sleep
    private let send: Send
    /// Compare zoom and history too (the daemon keeps them).
    private let tracksState: Bool
    private var page: BrowserTabState?
    private var observation: Task<Void, Never>?
    private var rebasing: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    /// The page change the pending write waits to send.
    private var unsent: BrowserTabState?

    init(tab: any BrowserTab, recorded: BrowserRecord, tracksState: Bool = false,
         daemonRecord: (@MainActor () -> BrowserRecord?)? = nil,
         delay: Duration, sleep: @escaping Sleep, send: @escaping Send) {
        self.recorded = recorded
        self.tracksState = tracksState
        self.delay = delay
        self.sleep = sleep
        self.send = send
        observation = Task { [weak self, tab] in
            for await state in Observations({ tab.state }) {
                self?.pageDidChange(state)
            }
        }
        if let daemonRecord {
            rebasing = Task { [weak self] in
                for await record in Observations({ daemonRecord() }) {
                    guard let record else { continue }
                    self?.rebase(record)
                }
            }
        }
    }

    /// Sends a write still waiting out its delay now (quit: the app may be
    /// gone before the delay ends).
    func flushNow() async {
        guard let state = unsent else { return }
        pending?.cancel()
        pending = nil
        unsent = nil
        await flush(state)
    }

    func cancel() {
        observation?.cancel()
        rebasing?.cancel()
        pending?.cancel()
        observation = nil
        rebasing = nil
        pending = nil
    }

    /// The daemon's record changed: compare the page against it from now on.
    private func rebase(_ record: BrowserRecord) {
        var record = record
        // Zoom and history are not compared when the daemon does not keep
        // them; keep the local copy so they never look changed.
        if !tracksState {
            record.zoom = recorded.zoom
            record.back = recorded.back
            record.forward = recorded.forward
        }
        guard record != recorded else { return }
        recorded = record
        if let page { pageDidChange(page) }
    }

    private func pageDidChange(_ state: BrowserTabState) {
        page = state
        pending?.cancel()
        guard recorded.update(toward: state, state: tracksState) != nil else {
            pending = nil
            unsent = nil
            return
        }
        unsent = state
        let delay = delay, sleep = sleep
        pending = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            self?.unsent = nil
            await self?.flush(state)
        }
    }

    private func flush(_ state: BrowserTabState) async {
        guard let update = recorded.update(toward: state, state: tracksState) else { return }
        let base = recorded
        guard await send(update) else { return }
        if recorded == base { recorded = base.applying(update) }
    }
}
